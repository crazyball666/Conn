import ConnSSH
import Foundation

package enum TmuxControlClientError: Error, Sendable, Equatable {
    case invalidLimits
    case invalidTimeout
    case notStarted
    case closed
    case commandRejected([Data])
    case operationOutcomeUnknown(TmuxControlUncertainCommand)
}

package struct TmuxControlClientLimits: Sendable, Equatable {
    package static let `default` = TmuxControlClientLimits(
        uncheckedMaxDiagnosticBytes: 64 * 1_024,
        parserLimits: .default,
        commandLimits: .default
    )

    package let maxDiagnosticBytes: Int
    package let parserLimits: TmuxProtocolParserLimits
    package let commandLimits: TmuxControlCommandLimits

    package init(
        maxDiagnosticBytes: Int,
        parserLimits: TmuxProtocolParserLimits = .default,
        commandLimits: TmuxControlCommandLimits = .default
    ) throws {
        guard maxDiagnosticBytes > 0 else {
            throw TmuxControlClientError.invalidLimits
        }
        self.maxDiagnosticBytes = maxDiagnosticBytes
        self.parserLimits = parserLimits
        self.commandLimits = commandLimits
    }

    private init(
        uncheckedMaxDiagnosticBytes: Int,
        parserLimits: TmuxProtocolParserLimits,
        commandLimits: TmuxControlCommandLimits
    ) {
        maxDiagnosticBytes = uncheckedMaxDiagnosticBytes
        self.parserLimits = parserLimits
        self.commandLimits = commandLimits
    }
}

package enum TmuxControlClientTermination: Sendable, Equatable {
    case requested
    case remoteExit(RemoteProcessExit)
    case transportFailure
    case protocolViolation
}

package enum TmuxControlClientEvent: Sendable, Equatable {
    case protocolReady(generation: UInt64)
    case notification(generation: UInt64, TmuxNotification)
    case stderrDiagnostic(generation: UInt64, data: Data)
    case diagnosticsTruncated(generation: UInt64, maximumBytes: Int)
    case reconciliationRequired(generation: UInt64, TmuxControlUncertainCommand?)
    case lateCommandTerminated(
        generation: UInt64,
        commandID: TmuxControlCommandID,
        status: TmuxControlCommandStatus
    )
    case closed(generation: UInt64, reason: TmuxControlClientTermination)
}

/// Owns one already-opened tmux Control Mode process channel. SSH engine selection and PTY+exec
/// creation remain outside this actor so no transport-specific fallback can leak into protocol
/// orchestration.
package actor TmuxControlClient {
    package typealias EventHandler = @Sendable (TmuxControlClientEvent) async -> Void

    private struct PendingExecution {
        let submission: TmuxControlCommandSubmission
        let continuation: CheckedContinuation<TmuxControlCommandResult, Error>
        var deadlineTask: Task<Void, Never>?
    }

    private let channel: any RemoteProcessChannel
    private let limits: TmuxControlClientLimits
    private let eventHandler: EventHandler
    private var parser: TmuxProtocolParser
    private var machine: TmuxControlCommandMachine
    private var readTask: Task<Void, Never>?
    private var pendingExecution: PendingExecution?
    private var diagnosticBytes = 0
    private var didReportDiagnosticTruncation = false
    private var started = false
    private var terminalized = false

    package init(
        channel: any RemoteProcessChannel,
        generation: UInt64,
        dialect: TmuxProtocolDialect,
        limits: TmuxControlClientLimits = .default,
        eventHandler: @escaping EventHandler = { _ in }
    ) throws {
        self.channel = channel
        self.limits = limits
        self.eventHandler = eventHandler
        parser = TmuxProtocolParser(dialect: dialect, limits: limits.parserLimits)
        machine = try TmuxControlCommandMachine(
            generation: generation,
            limits: limits.commandLimits
        )
    }

    package var generation: UInt64 {
        machine.generation
    }

    package var isReady: Bool {
        !terminalized && machine.isReady
    }

    package var isRecovering: Bool {
        !terminalized && machine.isRecovering
    }

    package func start() {
        guard !started, !terminalized else { return }
        started = true
        readTask = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    package func execute(
        _ operation: TmuxOperation,
        timeout: Duration
    ) async throws -> TmuxControlCommandResult {
        guard started else { throw TmuxControlClientError.notStarted }
        guard !terminalized else { throw TmuxControlClientError.closed }
        guard timeout > .zero else { throw TmuxControlClientError.invalidTimeout }

        let submission = try machine.submit(operation)
        return try await withCheckedThrowingContinuation { continuation in
            var execution = PendingExecution(
                submission: submission,
                continuation: continuation,
                deadlineTask: nil
            )
            execution.deadlineTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.deadlineReached(
                    commandID: submission.id,
                    generation: submission.generation
                )
            }
            pendingExecution = execution

            Task { [weak self, channel] in
                do {
                    try await channel.write(submission.wireData)
                } catch {
                    await self?.transportFailed(.transportFailure)
                }
            }
        }
    }

    package func markReconciled() throws {
        guard !terminalized else { throw TmuxControlClientError.closed }
        _ = try machine.markReconciled(generation: machine.generation)
    }

    package func close() async {
        await terminalize(reason: .requested, closeChannel: true)
    }

    private func runReadLoop() async {
        do {
            for try await output in channel.output {
                if Task.isCancelled { return }
                switch output {
                case let .stdout(data):
                    try await consumeStdout(data)
                case let .stderr(data):
                    await consumeStderr(data)
                }
            }

            for event in try parser.finish() {
                try await handle(event)
            }
            let exit = try await channel.result()
            await terminalize(reason: .remoteExit(exit), closeChannel: false)
        } catch is TmuxProtocolParserError {
            await transportFailed(.protocolViolation)
        } catch is TmuxControlCommandMachineError {
            await transportFailed(.protocolViolation)
        } catch is CancellationError {
            // Explicit close marks the actor terminal before cancelling this task.
            return
        } catch {
            await transportFailed(.transportFailure)
        }
    }

    private func consumeStdout(_ data: Data) async throws {
        for event in try parser.feed(data) {
            try await handle(event)
        }
    }

    private func consumeStderr(_ data: Data) async {
        guard !didReportDiagnosticTruncation else { return }
        let remaining = limits.maxDiagnosticBytes - diagnosticBytes
        if remaining > 0 {
            let retained = Data(data.prefix(remaining))
            if !retained.isEmpty {
                diagnosticBytes += retained.count
                await eventHandler(.stderrDiagnostic(
                    generation: machine.generation,
                    data: retained
                ))
            }
        }
        if data.count > remaining {
            didReportDiagnosticTruncation = true
            await eventHandler(.diagnosticsTruncated(
                generation: machine.generation,
                maximumBytes: limits.maxDiagnosticBytes
            ))
        }
    }

    private func handle(_ event: TmuxProtocolEvent) async throws {
        let action = try machine.receive(event, generation: machine.generation)
        switch action {
        case .none, .discardedStaleGeneration, .generationInstalled,
             .reconciliationCompleted, .commandTimedOut:
            return

        case .protocolReady:
            await eventHandler(.protocolReady(generation: machine.generation))

        case let .notification(notification):
            await eventHandler(.notification(
                generation: machine.generation,
                notification
            ))

        case let .commandCompleted(result):
            completePending(with: result)

        case let .lateCommandTerminated(commandID, status):
            await eventHandler(.lateCommandTerminated(
                generation: machine.generation,
                commandID: commandID,
                status: status
            ))

        case let .recoveryRequired(uncertain):
            await eventHandler(.reconciliationRequired(
                generation: machine.generation,
                uncertain
            ))

        case .protocolEnded:
            return
        }
    }

    private func completePending(with result: TmuxControlCommandResult) {
        guard let pending = pendingExecution,
              pending.submission.id == result.commandID,
              pending.submission.generation == result.generation
        else {
            return
        }
        pending.deadlineTask?.cancel()
        pendingExecution = nil
        switch result.status {
        case .succeeded:
            pending.continuation.resume(returning: result)
        case .rejected:
            pending.continuation.resume(
                throwing: TmuxControlClientError.commandRejected(result.output)
            )
        }
    }

    private func deadlineReached(
        commandID: TmuxControlCommandID,
        generation: UInt64
    ) async {
        guard !terminalized,
              let pending = pendingExecution,
              pending.submission.id == commandID,
              pending.submission.generation == generation
        else {
            return
        }

        do {
            let action = try machine.timeout(commandID, generation: generation)
            guard case let .commandTimedOut(uncertain) = action else { return }
            pendingExecution = nil
            pending.continuation.resume(
                throwing: TmuxControlClientError.operationOutcomeUnknown(uncertain)
            )
            await eventHandler(.reconciliationRequired(
                generation: generation,
                uncertain
            ))
        } catch {
            pendingExecution = nil
            pending.continuation.resume(throwing: error)
        }
    }

    private func transportFailed(_ reason: TmuxControlClientTermination) async {
        guard !terminalized else { return }

        let action = try? machine.channelLost(generation: machine.generation)
        let uncertain: TmuxControlUncertainCommand?
        if case let .recoveryRequired(command)? = action {
            uncertain = command
        } else {
            uncertain = nil
        }

        if let pending = pendingExecution {
            pending.deadlineTask?.cancel()
            pendingExecution = nil
            if let uncertain {
                pending.continuation.resume(
                    throwing: TmuxControlClientError.operationOutcomeUnknown(uncertain)
                )
            } else {
                pending.continuation.resume(throwing: TmuxControlClientError.closed)
            }
        }
        await eventHandler(.reconciliationRequired(
            generation: machine.generation,
            uncertain
        ))
        await terminalize(reason: reason, closeChannel: true)
    }

    private func terminalize(
        reason: TmuxControlClientTermination,
        closeChannel: Bool
    ) async {
        guard !terminalized else { return }
        terminalized = true

        let action = try? machine.channelLost(generation: machine.generation)
        let uncertain: TmuxControlUncertainCommand?
        if case let .recoveryRequired(command)? = action {
            uncertain = command
        } else {
            uncertain = nil
        }
        if let pending = pendingExecution {
            pending.deadlineTask?.cancel()
            pendingExecution = nil
            if let uncertain {
                pending.continuation.resume(
                    throwing: TmuxControlClientError.operationOutcomeUnknown(uncertain)
                )
            } else {
                pending.continuation.resume(throwing: TmuxControlClientError.closed)
            }
        }

        readTask?.cancel()
        readTask = nil
        if closeChannel {
            await channel.close()
        }
        await eventHandler(.closed(generation: machine.generation, reason: reason))
    }
}
