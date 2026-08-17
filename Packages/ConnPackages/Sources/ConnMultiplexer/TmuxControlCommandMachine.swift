import Foundation

package enum TmuxControlCommandMachineError: Error, Sendable, Equatable {
    case invalidLimits
    case protocolNotReady
    case commandAlreadyInFlight
    case commandIdentifierExhausted
    case commandNotInFlight
    case commandOutcomeAlreadyUnknown
    case reconciliationRequired
    case commandTerminationPending
    case generationReplacementRequired
    case invalidGenerationReplacement
    case unexpectedGeneration(expected: UInt64, actual: UInt64)
    case invalidProtocolSequence
    case guardMismatch(expected: TmuxCommandGuard, actual: TmuxCommandGuard)
    case outputLimitExceeded(maxBytes: Int, maxLines: Int)
    case terminalFailure
}

package struct TmuxControlCommandLimits: Sendable, Equatable {
    package static let `default` = TmuxControlCommandLimits(
        uncheckedMaxOutputBytes: 4 * 1_024 * 1_024,
        maxOutputLines: 4_096
    )

    package let maxOutputBytes: Int
    package let maxOutputLines: Int

    package init(maxOutputBytes: Int, maxOutputLines: Int) throws {
        guard maxOutputBytes > 0, maxOutputLines > 0 else {
            throw TmuxControlCommandMachineError.invalidLimits
        }
        self.maxOutputBytes = maxOutputBytes
        self.maxOutputLines = maxOutputLines
    }

    private init(uncheckedMaxOutputBytes: Int, maxOutputLines: Int) {
        maxOutputBytes = uncheckedMaxOutputBytes
        self.maxOutputLines = maxOutputLines
    }
}

package struct TmuxControlCommandID: RawRepresentable, Sendable, Equatable, Hashable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct TmuxControlCommandSubmission: Sendable, Equatable {
    package let id: TmuxControlCommandID
    package let generation: UInt64
    package let wireData: Data
    package let semantics: TmuxOperationSemantics
}

package enum TmuxControlCommandStatus: Sendable, Equatable {
    case succeeded
    case rejected
}

package struct TmuxControlCommandResult: Sendable, Equatable {
    package let commandID: TmuxControlCommandID
    package let generation: UInt64
    package let guardValue: TmuxCommandGuard
    package let output: [Data]
    package let status: TmuxControlCommandStatus

    package init(
        commandID: TmuxControlCommandID,
        generation: UInt64,
        guardValue: TmuxCommandGuard,
        output: [Data],
        status: TmuxControlCommandStatus
    ) {
        self.commandID = commandID
        self.generation = generation
        self.guardValue = guardValue
        self.output = output
        self.status = status
    }
}

package struct TmuxControlUncertainCommand: Sendable, Equatable {
    package let commandID: TmuxControlCommandID
    package let generation: UInt64
    package let semantics: TmuxOperationSemantics
    package let output: [Data]

    package init(
        commandID: TmuxControlCommandID,
        generation: UInt64,
        semantics: TmuxOperationSemantics,
        output: [Data]
    ) {
        self.commandID = commandID
        self.generation = generation
        self.semantics = semantics
        self.output = output
    }
}

package enum TmuxControlCommandMachineAction: Sendable, Equatable {
    case none
    case protocolReady
    case notification(TmuxNotification)
    case commandCompleted(TmuxControlCommandResult)
    case commandTimedOut(TmuxControlUncertainCommand)
    case lateCommandTerminated(commandID: TmuxControlCommandID, status: TmuxControlCommandStatus)
    case reconciliationCompleted
    case recoveryRequired(TmuxControlUncertainCommand?)
    case generationInstalled(UInt64)
    case discardedStaleGeneration
    case protocolEnded
}

/// Pure command correlator for one Control Mode channel generation. The parser establishes
/// protocol framing; this machine establishes command ownership and independently bounds the
/// aggregate response retained for a caller.
package struct TmuxControlCommandMachine: Sendable {
    /// `tmux -CC attach-session` always answers the attach command with one initial
    /// `%begin`/`%end` block after the DCS marker. That block is owned by tmux startup,
    /// not by a command submitted through this machine.
    private struct BootstrapCommand: Sendable {
        var guardValue: TmuxCommandGuard?
        var outputBytes = 0
        var outputLines = 0
    }

    private struct PendingCommand: Sendable {
        let submission: TmuxControlCommandSubmission
        let completionMarker: Data?
        var guardValue: TmuxCommandGuard?
        var currentBlockOutputStart: Int?
        var output: [Data]
        var outputBytes: Int
        var timedOut: Bool
    }

    private enum State: Sendable {
        case awaitingProtocolStart
        case bootstrapping(BootstrapCommand)
        case ready
        case pending(PendingCommand)
        case awaitingReconciliation
        case awaitingReplacement
        case ended
        case failed
    }

    package private(set) var generation: UInt64
    private let limits: TmuxControlCommandLimits
    private let renderer = TmuxControlCommandRenderer()
    private var nextCommandID: UInt64 = 0
    private var state: State = .awaitingProtocolStart

    package init(
        generation: UInt64,
        limits: TmuxControlCommandLimits = .default
    ) throws {
        self.generation = generation
        self.limits = limits
    }

    package var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    package var isRecovering: Bool {
        switch state {
        case let .pending(pending):
            pending.timedOut
        case .awaitingReconciliation, .awaitingReplacement:
            true
        case .awaitingProtocolStart, .bootstrapping, .ready, .ended, .failed:
            false
        }
    }

    package var requiresReconciliation: Bool {
        switch state {
        case let .pending(pending):
            pending.timedOut
        case .awaitingReconciliation:
            true
        case .awaitingProtocolStart, .bootstrapping, .ready, .awaitingReplacement, .ended, .failed:
            false
        }
    }

    package var isTerminalFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    package mutating func submit(
        _ operation: TmuxOperation
    ) throws -> TmuxControlCommandSubmission {
        try submit(TmuxControlRequest(
            renderedCommand: renderer.render(operation),
            semantics: operation.semantics
        ))
    }

    package mutating func submit(
        _ request: TmuxControlRequest
    ) throws -> TmuxControlCommandSubmission {
        switch state {
        case .awaitingProtocolStart, .bootstrapping:
            throw TmuxControlCommandMachineError.protocolNotReady
        case .ready:
            break
        case let .pending(pending):
            throw pending.timedOut
                ? TmuxControlCommandMachineError.reconciliationRequired
                : TmuxControlCommandMachineError.commandAlreadyInFlight
        case .awaitingReconciliation, .awaitingReplacement:
            throw TmuxControlCommandMachineError.reconciliationRequired
        case .ended, .failed:
            throw TmuxControlCommandMachineError.terminalFailure
        }

        guard nextCommandID < UInt64.max else {
            state = .failed
            throw TmuxControlCommandMachineError.commandIdentifierExhausted
        }
        let submission = TmuxControlCommandSubmission(
            id: .init(rawValue: nextCommandID),
            generation: generation,
            wireData: request.wireData,
            semantics: request.semantics
        )
        nextCommandID += 1
        state = .pending(PendingCommand(
            submission: submission,
            completionMarker: request.completionMarker,
            guardValue: nil,
            currentBlockOutputStart: nil,
            output: [],
            outputBytes: 0,
            timedOut: false
        ))
        return submission
    }

    package mutating func receive(
        _ event: TmuxProtocolEvent,
        generation eventGeneration: UInt64
    ) throws -> TmuxControlCommandMachineAction {
        if eventGeneration < generation {
            return .discardedStaleGeneration
        }
        guard eventGeneration == generation else {
            throw TmuxControlCommandMachineError.unexpectedGeneration(
                expected: generation,
                actual: eventGeneration
            )
        }
        guard !isTerminalFailure else {
            throw TmuxControlCommandMachineError.terminalFailure
        }

        do {
            return try apply(event)
        } catch let error as TmuxControlCommandMachineError {
            state = .failed
            throw error
        } catch {
            state = .failed
            throw error
        }
    }

    package mutating func timeout(
        _ commandID: TmuxControlCommandID,
        generation eventGeneration: UInt64
    ) throws -> TmuxControlCommandMachineAction {
        if eventGeneration < generation { return .discardedStaleGeneration }
        guard eventGeneration == generation else {
            throw TmuxControlCommandMachineError.unexpectedGeneration(
                expected: generation,
                actual: eventGeneration
            )
        }
        guard case var .pending(pending) = state,
              pending.submission.id == commandID
        else {
            throw TmuxControlCommandMachineError.commandNotInFlight
        }
        guard !pending.timedOut else {
            throw TmuxControlCommandMachineError.commandOutcomeAlreadyUnknown
        }
        pending.timedOut = true
        state = .pending(pending)
        return .commandTimedOut(uncertainCommand(from: pending))
    }

    package mutating func markReconciled(
        generation eventGeneration: UInt64
    ) throws -> TmuxControlCommandMachineAction {
        if eventGeneration < generation { return .discardedStaleGeneration }
        guard eventGeneration == generation else {
            throw TmuxControlCommandMachineError.unexpectedGeneration(
                expected: generation,
                actual: eventGeneration
            )
        }
        switch state {
        case let .pending(pending) where pending.timedOut:
            throw TmuxControlCommandMachineError.commandTerminationPending
        case .awaitingReconciliation:
            state = .ready
            return .reconciliationCompleted
        case .awaitingReplacement:
            throw TmuxControlCommandMachineError.generationReplacementRequired
        case .ready:
            return .reconciliationCompleted
        case .awaitingProtocolStart, .bootstrapping, .pending, .ended, .failed:
            throw TmuxControlCommandMachineError.invalidProtocolSequence
        }
    }

    package mutating func channelLost(
        generation eventGeneration: UInt64
    ) throws -> TmuxControlCommandMachineAction {
        if eventGeneration < generation { return .discardedStaleGeneration }
        guard eventGeneration == generation else {
            throw TmuxControlCommandMachineError.unexpectedGeneration(
                expected: generation,
                actual: eventGeneration
            )
        }
        let uncertain: TmuxControlUncertainCommand?
        if case let .pending(pending) = state {
            uncertain = uncertainCommand(from: pending)
        } else {
            uncertain = nil
        }
        state = .awaitingReplacement
        return .recoveryRequired(uncertain)
    }

    package mutating func installGeneration(
        _ newGeneration: UInt64
    ) throws -> TmuxControlCommandMachineAction {
        guard newGeneration > generation else {
            throw TmuxControlCommandMachineError.invalidGenerationReplacement
        }
        generation = newGeneration
        nextCommandID = 0
        state = .awaitingProtocolStart
        return .generationInstalled(newGeneration)
    }

    private mutating func apply(
        _ event: TmuxProtocolEvent
    ) throws -> TmuxControlCommandMachineAction {
        switch event {
        case .protocolStarted:
            guard case .awaitingProtocolStart = state else {
                throw TmuxControlCommandMachineError.invalidProtocolSequence
            }
            state = .bootstrapping(BootstrapCommand())
            return .none

        case let .notification(notification):
            switch state {
            case .ready, .pending, .awaitingReconciliation:
                return .notification(notification)
            case .awaitingProtocolStart, .bootstrapping, .awaitingReplacement, .ended, .failed:
                throw TmuxControlCommandMachineError.invalidProtocolSequence
            }

        case let .commandBegin(guardValue):
            if case var .bootstrapping(bootstrap) = state {
                guard bootstrap.guardValue == nil else {
                    throw TmuxControlCommandMachineError.invalidProtocolSequence
                }
                bootstrap.guardValue = guardValue
                state = .bootstrapping(bootstrap)
                return .none
            }
            guard case var .pending(pending) = state,
                  pending.guardValue == nil
            else {
                throw TmuxControlCommandMachineError.invalidProtocolSequence
            }
            pending.guardValue = guardValue
            pending.currentBlockOutputStart = pending.output.count
            state = .pending(pending)
            return .none

        case let .commandOutput(data):
            if case var .bootstrapping(bootstrap) = state {
                guard bootstrap.guardValue != nil else {
                    throw TmuxControlCommandMachineError.invalidProtocolSequence
                }
                guard bootstrap.outputLines < limits.maxOutputLines,
                      data.count <= limits.maxOutputBytes - bootstrap.outputBytes
                else {
                    throw TmuxControlCommandMachineError.outputLimitExceeded(
                        maxBytes: limits.maxOutputBytes,
                        maxLines: limits.maxOutputLines
                    )
                }
                bootstrap.outputLines += 1
                bootstrap.outputBytes += data.count
                state = .bootstrapping(bootstrap)
                return .none
            }
            guard case var .pending(pending) = state,
                  pending.guardValue != nil
            else {
                throw TmuxControlCommandMachineError.invalidProtocolSequence
            }
            guard pending.output.count < limits.maxOutputLines,
                  data.count <= limits.maxOutputBytes - pending.outputBytes
            else {
                throw TmuxControlCommandMachineError.outputLimitExceeded(
                    maxBytes: limits.maxOutputBytes,
                    maxLines: limits.maxOutputLines
                )
            }
            pending.output.append(data)
            pending.outputBytes += data.count
            state = .pending(pending)
            return .none

        case let .commandEnd(actualGuard):
            if case let .bootstrapping(bootstrap) = state {
                guard bootstrap.guardValue == actualGuard else {
                    throw TmuxControlCommandMachineError.invalidProtocolSequence
                }
                state = .ready
                return .protocolReady
            }
            return try complete(actualGuard, status: .succeeded)

        case let .commandError(actualGuard):
            if case let .bootstrapping(bootstrap) = state,
               bootstrap.guardValue == actualGuard
            {
                throw TmuxControlCommandMachineError.invalidProtocolSequence
            }
            return try complete(actualGuard, status: .rejected)

        case .protocolEnded:
            switch state {
            case .ready, .awaitingReconciliation:
                state = .ended
                return .protocolEnded
            case let .pending(pending):
                let uncertain = uncertainCommand(from: pending)
                state = .awaitingReplacement
                return .recoveryRequired(uncertain)
            case .awaitingProtocolStart, .bootstrapping, .awaitingReplacement, .ended, .failed:
                throw TmuxControlCommandMachineError.invalidProtocolSequence
            }
        }
    }

    private mutating func complete(
        _ actualGuard: TmuxCommandGuard,
        status: TmuxControlCommandStatus
    ) throws -> TmuxControlCommandMachineAction {
        guard case var .pending(pending) = state,
              let expectedGuard = pending.guardValue,
              let blockOutputStart = pending.currentBlockOutputStart
        else {
            throw TmuxControlCommandMachineError.invalidProtocolSequence
        }
        guard expectedGuard == actualGuard else {
            throw TmuxControlCommandMachineError.guardMismatch(
                expected: expectedGuard,
                actual: actualGuard
            )
        }
        if status == .succeeded, let completionMarker = pending.completionMarker {
            let blockOutput = pending.output[blockOutputStart...]
            if !blockOutput.isEmpty, pending.output.last == completionMarker {
                pending.output.removeLast()
                pending.outputBytes -= completionMarker.count
            } else {
                pending.guardValue = nil
                pending.currentBlockOutputStart = nil
                state = .pending(pending)
                return .none
            }
        }
        if pending.timedOut {
            state = .awaitingReconciliation
            return .lateCommandTerminated(
                commandID: pending.submission.id,
                status: status
            )
        }
        let result = TmuxControlCommandResult(
            commandID: pending.submission.id,
            generation: generation,
            guardValue: actualGuard,
            output: pending.output,
            status: status
        )
        state = .ready
        return .commandCompleted(result)
    }

    private func uncertainCommand(from pending: PendingCommand) -> TmuxControlUncertainCommand {
        TmuxControlUncertainCommand(
            commandID: pending.submission.id,
            generation: pending.submission.generation,
            semantics: pending.submission.semantics,
            output: pending.output
        )
    }
}
