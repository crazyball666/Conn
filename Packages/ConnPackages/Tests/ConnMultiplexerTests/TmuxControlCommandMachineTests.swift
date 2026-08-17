@testable import ConnMultiplexer
import Foundation
import Testing

@Suite("tmux control command machine")
struct TmuxControlCommandMachineTests {
    @Test("typed read-only requests own bounded single-line wire data and explicit semantics")
    func submitsTypedReadOnlyRequest() throws {
        let command = "display-message -p '#{server_pid}'"
        let request = try TmuxControlRequest(
            renderedCommand: .init(value: command),
            semantics: .readOnly
        )
        var machine = try CommandMachineFixture().readyMachine()

        #expect(request.wireData == Data((command + "\n").utf8))
        #expect(request.semantics == .readOnly)

        let submission = try machine.submit(request)
        #expect(submission.wireData == request.wireData)
        #expect(submission.semantics == .readOnly)

        #expect(throws: TmuxControlRequestError.invalidCommand) {
            try TmuxControlRequest(
                renderedCommand: .init(value: "list-sessions\nkill-server"),
                semantics: .readOnly
            )
        }
        #expect(throws: TmuxControlRequestError.invalidCommand) {
            try TmuxControlRequest(
                renderedCommand: .init(value: "list-sessions\u{85}kill-server"),
                semantics: .readOnly
            )
        }
        #expect(throws: TmuxControlRequestError.commandTooLong(
            maximumBytes: TmuxControlRequest.maximumCommandBytes
        )) {
            try TmuxControlRequest(
                renderedCommand: .init(
                    value: String(repeating: "x", count: TmuxControlRequest.maximumCommandBytes + 1)
                ),
                semantics: .readOnly
            )
        }
    }

    @Test("protocol readiness gates one command and correlates a successful response")
    func correlatesSuccessfulCommand() throws {
        let fixture = try CommandMachineFixture()
        var machine = try TmuxControlCommandMachine(generation: 7)

        #expect(throws: TmuxControlCommandMachineError.protocolNotReady) {
            try machine.submit(fixture.renameSession)
        }
        #expect(try machine.receive(.protocolStarted, generation: 7) == .none)
        #expect(!machine.isReady)
        #expect(throws: TmuxControlCommandMachineError.protocolNotReady) {
            try machine.submit(fixture.renameSession)
        }
        let bootstrapGuard = TmuxCommandGuard(time: 9, commandNumber: 1, flags: 0)
        #expect(try machine.receive(.commandBegin(bootstrapGuard), generation: 7) == .none)
        #expect(try machine.receive(.commandEnd(bootstrapGuard), generation: 7) == .protocolReady)

        let submission = try machine.submit(fixture.renameSession)
        #expect(submission.id.rawValue == 0)
        #expect(submission.generation == 7)
        #expect(submission.semantics == .idempotentMutation)
        #expect(submission.wireData.last == UInt8(ascii: "\n"))
        #expect(throws: TmuxControlCommandMachineError.commandAlreadyInFlight) {
            try machine.submit(fixture.killPane)
        }

        let notification = TmuxNotification.known(.sessionsChanged, payload: Data("before".utf8))
        #expect(try machine.receive(.notification(notification), generation: 7) == .notification(notification))

        let guardValue = TmuxCommandGuard(time: 10, commandNumber: 2, flags: 0)
        #expect(try machine.receive(.commandBegin(guardValue), generation: 7) == .none)
        #expect(try machine.receive(.commandOutput(Data("one".utf8)), generation: 7) == .none)
        #expect(try machine.receive(.commandOutput(Data("two".utf8)), generation: 7) == .none)

        let expected = TmuxControlCommandResult(
            commandID: submission.id,
            generation: 7,
            guardValue: guardValue,
            output: [Data("one".utf8), Data("two".utf8)],
            status: .succeeded
        )
        #expect(try machine.receive(.commandEnd(guardValue), generation: 7) == .commandCompleted(expected))
        #expect(machine.isReady)

        let next = try machine.submit(fixture.killPane)
        #expect(next.id.rawValue == 1)
        #expect(next.semantics == .destructive)
    }

    @Test("tmux error preserves bounded output and frees the serial command slot")
    func correlatesRejectedCommand() throws {
        let fixture = try CommandMachineFixture()
        var machine = try fixture.readyMachine()
        let submission = try machine.submit(fixture.killPane)
        let guardValue = TmuxCommandGuard(time: 11, commandNumber: 3, flags: nil)

        _ = try machine.receive(.commandBegin(guardValue), generation: 7)
        _ = try machine.receive(.commandOutput(Data("can't find pane".utf8)), generation: 7)

        let expected = TmuxControlCommandResult(
            commandID: submission.id,
            generation: 7,
            guardValue: guardValue,
            output: [Data("can't find pane".utf8)],
            status: .rejected
        )
        #expect(try machine.receive(.commandError(guardValue), generation: 7) == .commandCompleted(expected))
        #expect(machine.isReady)
        _ = try machine.submit(fixture.renameSession)
    }

    @Test("nonce completion marker correlates a real multi-block command sequence")
    func correlatesMultiBlockSequence() throws {
        let marker = "__CONN_TEST_REQUEST_END__"
        let request = try TmuxControlRequest(
            renderedCommand: .init(
                value: "list-sessions ; display-message -p '\(marker)'"
            ),
            semantics: .readOnly,
            completionMarker: marker
        )
        var machine = try CommandMachineFixture().readyMachine()
        let submission = try machine.submit(request)
        let firstGuard = TmuxCommandGuard(time: 12, commandNumber: 4, flags: 1)
        let finalGuard = TmuxCommandGuard(time: 12, commandNumber: 5, flags: 1)

        #expect(try machine.receive(.commandBegin(firstGuard), generation: 7) == .none)
        #expect(try machine.receive(.commandOutput(Data("$1".utf8)), generation: 7) == .none)
        #expect(try machine.receive(.commandEnd(firstGuard), generation: 7) == .none)
        #expect(try machine.receive(.commandBegin(finalGuard), generation: 7) == .none)
        #expect(try machine.receive(.commandOutput(Data(marker.utf8)), generation: 7) == .none)
        #expect(try machine.receive(.commandEnd(finalGuard), generation: 7) == .commandCompleted(
            TmuxControlCommandResult(
                commandID: submission.id,
                generation: 7,
                guardValue: finalGuard,
                output: [Data("$1".utf8)],
                status: .succeeded
            )
        ))
        #expect(machine.isReady)
    }

    @Test("notifications preserve wire order before and between command blocks")
    func forwardsNotificationsInOrder() throws {
        let fixture = try CommandMachineFixture()
        var machine = try fixture.readyMachine()
        let first = TmuxNotification.known(.sessionRenamed, payload: Data("$1 first".utf8))
        let second = TmuxNotification.unknown(name: "future", payload: Data("opaque".utf8))

        #expect(try machine.receive(.notification(first), generation: 7) == .notification(first))
        let submission = try machine.submit(fixture.renameSession)
        let guardValue = TmuxCommandGuard(time: 12, commandNumber: 4, flags: 0)
        _ = try machine.receive(.commandBegin(guardValue), generation: 7)
        #expect(try machine.receive(.commandEnd(guardValue), generation: 7) == .commandCompleted(.init(
            commandID: submission.id,
            generation: 7,
            guardValue: guardValue,
            output: [],
            status: .succeeded
        )))
        #expect(try machine.receive(.notification(second), generation: 7) == .notification(second))
    }

    @Test("response output has independent byte and line bounds")
    func boundsCommandOutput() throws {
        let fixture = try CommandMachineFixture()

        var bytesMachine = try fixture.readyMachine(maxOutputBytes: 5, maxOutputLines: 3)
        _ = try bytesMachine.submit(fixture.renameSession)
        let bytesGuard = TmuxCommandGuard(time: 13, commandNumber: 5, flags: 0)
        _ = try bytesMachine.receive(.commandBegin(bytesGuard), generation: 7)
        _ = try bytesMachine.receive(.commandOutput(Data("123".utf8)), generation: 7)
        #expect(throws: TmuxControlCommandMachineError.outputLimitExceeded(
            maxBytes: 5,
            maxLines: 3
        )) {
            try bytesMachine.receive(.commandOutput(Data("456".utf8)), generation: 7)
        }
        #expect(bytesMachine.isTerminalFailure)

        var linesMachine = try fixture.readyMachine(maxOutputBytes: 100, maxOutputLines: 1)
        _ = try linesMachine.submit(fixture.renameSession)
        let linesGuard = TmuxCommandGuard(time: 14, commandNumber: 6, flags: 0)
        _ = try linesMachine.receive(.commandBegin(linesGuard), generation: 7)
        _ = try linesMachine.receive(.commandOutput(Data("one".utf8)), generation: 7)
        #expect(throws: TmuxControlCommandMachineError.outputLimitExceeded(
            maxBytes: 100,
            maxLines: 1
        )) {
            try linesMachine.receive(.commandOutput(Data("two".utf8)), generation: 7)
        }
        #expect(linesMachine.isTerminalFailure)
    }

    @Test("invalid ordering and guard mismatch fail closed")
    func rejectsInvalidProtocolOrdering() throws {
        let fixture = try CommandMachineFixture()
        let guardValue = TmuxCommandGuard(time: 15, commandNumber: 7, flags: 0)

        var beginWithoutCommand = try fixture.readyMachine()
        #expect(throws: TmuxControlCommandMachineError.invalidProtocolSequence) {
            try beginWithoutCommand.receive(.commandBegin(guardValue), generation: 7)
        }
        #expect(beginWithoutCommand.isTerminalFailure)

        var outputWithoutBegin = try fixture.readyMachine()
        _ = try outputWithoutBegin.submit(fixture.renameSession)
        #expect(throws: TmuxControlCommandMachineError.invalidProtocolSequence) {
            try outputWithoutBegin.receive(.commandOutput(Data()), generation: 7)
        }
        #expect(outputWithoutBegin.isTerminalFailure)

        var mismatch = try fixture.readyMachine()
        _ = try mismatch.submit(fixture.renameSession)
        _ = try mismatch.receive(.commandBegin(guardValue), generation: 7)
        let otherGuard = TmuxCommandGuard(time: 15, commandNumber: 8, flags: 0)
        #expect(throws: TmuxControlCommandMachineError.guardMismatch(
            expected: guardValue,
            actual: otherGuard
        )) {
            try mismatch.receive(.commandEnd(otherGuard), generation: 7)
        }
        #expect(mismatch.isTerminalFailure)
        #expect(throws: TmuxControlCommandMachineError.terminalFailure) {
            try mismatch.submit(fixture.killPane)
        }
    }

    @Test("timeout before begin keeps tracking the late block and requires reconciliation")
    func quarantinesTimeoutBeforeBegin() throws {
        let fixture = try CommandMachineFixture()
        var machine = try fixture.readyMachine()
        let submission = try machine.submit(fixture.killPane)
        let uncertain = TmuxControlUncertainCommand(
            commandID: submission.id,
            generation: 7,
            semantics: .destructive,
            output: []
        )

        #expect(try machine.timeout(submission.id, generation: 7) == .commandTimedOut(uncertain))
        #expect(machine.isRecovering)
        #expect(throws: TmuxControlCommandMachineError.reconciliationRequired) {
            try machine.submit(fixture.renameSession)
        }
        #expect(throws: TmuxControlCommandMachineError.commandTerminationPending) {
            try machine.markReconciled(generation: 7)
        }

        let guardValue = TmuxCommandGuard(time: 20, commandNumber: 10, flags: 0)
        #expect(try machine.receive(.commandBegin(guardValue), generation: 7) == .none)
        #expect(try machine.receive(.commandOutput(Data("late".utf8)), generation: 7) == .none)
        #expect(try machine.receive(.commandEnd(guardValue), generation: 7) == .lateCommandTerminated(
            commandID: submission.id,
            status: .succeeded
        ))
        #expect(machine.requiresReconciliation)
        #expect(!machine.isReady)
        #expect(throws: TmuxControlCommandMachineError.reconciliationRequired) {
            try machine.submit(fixture.renameSession)
        }

        #expect(try machine.markReconciled(generation: 7) == .reconciliationCompleted)
        #expect(machine.isReady)
        _ = try machine.submit(fixture.renameSession)
    }

    @Test("timeout after begin never turns a late error or success into caller completion")
    func quarantinesTimeoutAfterBegin() throws {
        let fixture = try CommandMachineFixture()
        var machine = try fixture.readyMachine()
        let submission = try machine.submit(fixture.killPane)
        let guardValue = TmuxCommandGuard(time: 21, commandNumber: 11, flags: 0)
        _ = try machine.receive(.commandBegin(guardValue), generation: 7)
        _ = try machine.receive(.commandOutput(Data("partial".utf8)), generation: 7)

        #expect(try machine.timeout(submission.id, generation: 7) == .commandTimedOut(.init(
            commandID: submission.id,
            generation: 7,
            semantics: .destructive,
            output: [Data("partial".utf8)]
        )))
        #expect(try machine.receive(.commandError(guardValue), generation: 7) == .lateCommandTerminated(
            commandID: submission.id,
            status: .rejected
        ))
        #expect(machine.requiresReconciliation)
    }

    @Test("channel loss quarantines uncertain mutation until a strictly newer generation")
    func requiresNewGenerationAfterChannelLoss() throws {
        let fixture = try CommandMachineFixture()
        var machine = try fixture.readyMachine()
        let submission = try machine.submit(fixture.killPane)

        #expect(try machine.channelLost(generation: 7) == .recoveryRequired(.init(
            commandID: submission.id,
            generation: 7,
            semantics: .destructive,
            output: []
        )))
        #expect(machine.isRecovering)
        #expect(throws: TmuxControlCommandMachineError.generationReplacementRequired) {
            try machine.markReconciled(generation: 7)
        }
        #expect(throws: TmuxControlCommandMachineError.reconciliationRequired) {
            try machine.submit(fixture.renameSession)
        }

        #expect(try machine.installGeneration(8) == .generationInstalled(8))
        #expect(try machine.receive(.protocolStarted, generation: 7) == .discardedStaleGeneration)
        #expect(!machine.isReady)
        #expect(try machine.receive(.protocolStarted, generation: 8) == .none)
        let bootstrapGuard = TmuxCommandGuard(time: 16, commandNumber: 9, flags: 0)
        #expect(try machine.receive(.commandBegin(bootstrapGuard), generation: 8) == .none)
        #expect(try machine.receive(.commandEnd(bootstrapGuard), generation: 8) == .protocolReady)
        #expect(machine.isReady)
        let next = try machine.submit(fixture.renameSession)
        #expect(next.generation == 8)
        #expect(next.id.rawValue == 0)
    }

    @Test("old generations are discarded and future generations cannot corrupt current state")
    func isolatesEventGenerations() throws {
        let fixture = try CommandMachineFixture()
        var machine = try fixture.readyMachine()
        let notification = TmuxNotification.known(.sessionsChanged, payload: Data())

        #expect(try machine.receive(.notification(notification), generation: 6) == .discardedStaleGeneration)
        #expect(throws: TmuxControlCommandMachineError.unexpectedGeneration(
            expected: 7,
            actual: 8
        )) {
            try machine.receive(.notification(notification), generation: 8)
        }
        #expect(machine.isReady)
        #expect(try machine.receive(.notification(notification), generation: 7) == .notification(notification))
        #expect(throws: TmuxControlCommandMachineError.invalidGenerationReplacement) {
            try machine.installGeneration(7)
        }
    }
}

private struct CommandMachineFixture {
    let session: TmuxSessionID
    let pane: TmuxPaneID
    let renameSession: TmuxOperation
    let killPane: TmuxOperation

    init() throws {
        session = try #require(TmuxSessionID(rawValue: "$1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        renameSession = .renameSession(session, to: try TmuxName("renamed"))
        killPane = .killPane(pane)
    }

    func readyMachine(
        maxOutputBytes: Int = 1_024,
        maxOutputLines: Int = 32
    ) throws -> TmuxControlCommandMachine {
        var machine = try TmuxControlCommandMachine(
            generation: 7,
            limits: .init(maxOutputBytes: maxOutputBytes, maxOutputLines: maxOutputLines)
        )
        _ = try machine.receive(.protocolStarted, generation: 7)
        let bootstrapGuard = TmuxCommandGuard(time: 1, commandNumber: 1, flags: 0)
        _ = try machine.receive(.commandBegin(bootstrapGuard), generation: 7)
        _ = try machine.receive(.commandEnd(bootstrapGuard), generation: 7)
        return machine
    }
}
