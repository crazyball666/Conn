import ConnMultiplexer
import Foundation
import Testing

@Suite("tmux control command machine")
struct TmuxControlCommandMachineTests {
    @Test("protocol readiness gates one command and correlates a successful response")
    func correlatesSuccessfulCommand() throws {
        let fixture = try CommandMachineFixture()
        var machine = try TmuxControlCommandMachine(generation: 7)

        #expect(throws: TmuxControlCommandMachineError.protocolNotReady) {
            try machine.submit(fixture.renameSession)
        }
        #expect(try machine.receive(.protocolStarted, generation: 7) == .protocolReady)

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
        return machine
    }
}
