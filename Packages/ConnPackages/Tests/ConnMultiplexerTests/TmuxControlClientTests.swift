import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux control client")
struct TmuxControlClientTests {
    @Test("arbitrary stdout chunks drive protocol while stderr stays bounded diagnostics")
    func parsesOnlyStdoutAndForwardsWireOrder() async throws {
        let fixture = try ControlClientFixture()
        let channel = ScriptedControlProcessChannel()
        let events = ControlClientEventRecorder()
        let client = try TmuxControlClient(
            channel: channel,
            generation: 7,
            dialect: fixture.dialect,
            limits: .init(maxDiagnosticBytes: 5),
            eventHandler: { await events.append($0) }
        )
        await client.start()

        channel.yield(.stderr(Data("%begin 9 9 0\n".utf8)))
        channel.yield(.stderr(Data("overflow".utf8)))
        for chunk in fixture.chunks(of: fixture.startMarker, splitAt: [1, 4]) {
            channel.yield(.stdout(chunk))
        }
        #expect(await waitUntil { await events.contains(.protocolReady(generation: 7)) })

        let command = Task {
            try await client.execute(fixture.renameSession, timeout: .seconds(1))
        }
        #expect(await waitUntil { await channel.recordedWrites().count == 1 })

        let notification = "%sessions-changed\n"
        let response = "%begin 10 2 0\none\ntwo\n%end 10 2 0\n"
        for chunk in fixture.chunks(
            of: Data((notification + response).utf8),
            splitAt: [2, 9, 21, 35]
        ) {
            channel.yield(.stdout(chunk))
        }

        let result = try await command.value
        #expect(result.status == .succeeded)
        #expect(result.output == [Data("one".utf8), Data("two".utf8)])
        #expect(await channel.recordedWrites() == [fixture.renderedRename])
        #expect(await events.values() == [
            .stderrDiagnostic(generation: 7, data: Data("%begi".utf8)),
            .diagnosticsTruncated(generation: 7, maximumBytes: 5),
            .protocolReady(generation: 7),
            .notification(
                generation: 7,
                .known(.sessionsChanged, payload: Data())
            ),
        ])
        await client.close()
    }

    @Test("one response-bearing write is allowed and concurrent commands are rejected")
    func serializesCommandWrites() async throws {
        let fixture = try ControlClientFixture()
        let channel = ScriptedControlProcessChannel()
        let client = try fixture.startedClient(channel: channel)
        channel.yield(.stdout(fixture.startMarker))
        #expect(await waitUntil { await client.isReady })

        let first = Task {
            try await client.execute(fixture.renameSession, timeout: .seconds(1))
        }
        #expect(await waitUntil { await channel.recordedWrites().count == 1 })
        await #expect(throws: TmuxControlCommandMachineError.commandAlreadyInFlight) {
            try await client.execute(fixture.killPane, timeout: .seconds(1))
        }
        #expect(await channel.recordedWrites().count == 1)

        channel.yield(.stdout(Data("%begin 11 3 0\n%end 11 3 0\n".utf8)))
        #expect(try await first.value.status == .succeeded)
        await client.close()
    }

    @Test("deadline reports unknown once and late success only requests reconciliation")
    func quarantinesDeadlineAndLateSuccess() async throws {
        let fixture = try ControlClientFixture()
        let channel = ScriptedControlProcessChannel()
        let events = ControlClientEventRecorder()
        let client = try fixture.startedClient(channel: channel) {
            await events.append($0)
        }
        channel.yield(.stdout(fixture.startMarker))
        #expect(await waitUntil { await client.isReady })

        do {
            _ = try await client.execute(fixture.killPane, timeout: .milliseconds(20))
            Issue.record("destructive command should time out as outcome unknown")
        } catch let error as TmuxControlClientError {
            guard case let .operationOutcomeUnknown(uncertain) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(uncertain.semantics == .destructive)
            #expect(uncertain.generation == 7)
        }
        #expect(await channel.recordedWrites() == [fixture.renderedKillPane])
        #expect(await client.isRecovering)

        channel.yield(.stdout(Data("%begin 12 4 0\nlate\n%end 12 4 0\n".utf8)))
        #expect(await waitUntil {
            await events.contains(.lateCommandTerminated(
                generation: 7,
                commandID: .init(rawValue: 0),
                status: .succeeded
            ))
        })
        await #expect(throws: TmuxControlCommandMachineError.reconciliationRequired) {
            try await client.execute(fixture.renameSession, timeout: .seconds(1))
        }

        try await client.markReconciled()
        #expect(await client.isReady)
        await client.close()
    }

    @Test("transport loss never retries an uncertain mutation and closes once")
    func handlesTransportLossWithoutReplay() async throws {
        let fixture = try ControlClientFixture()
        let channel = ScriptedControlProcessChannel()
        let events = ControlClientEventRecorder()
        let client = try fixture.startedClient(channel: channel) {
            await events.append($0)
        }
        channel.yield(.stdout(fixture.startMarker))
        #expect(await waitUntil { await client.isReady })

        let operation = Task {
            try await client.execute(fixture.killPane, timeout: .seconds(1))
        }
        #expect(await waitUntil { await channel.recordedWrites().count == 1 })
        channel.failOutput(TestControlChannelError.lost)

        do {
            _ = try await operation.value
            Issue.record("transport loss after write should be outcome unknown")
        } catch let error as TmuxControlClientError {
            guard case .operationOutcomeUnknown = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(await channel.recordedWrites() == [fixture.renderedKillPane])
        #expect(await waitUntil { await events.closedCount == 1 })
        #expect(await events.containsRecovery(generation: 7, hasUncertainCommand: true))
        #expect(await events.closedCount == 1)
        await client.close()
        #expect(await events.closedCount == 1)
    }

    @Test("explicit close racing normal result is idempotent and completes a waiter once")
    func closesExactlyOnceAcrossResultRace() async throws {
        let fixture = try ControlClientFixture()
        let channel = ScriptedControlProcessChannel()
        let events = ControlClientEventRecorder()
        let client = try fixture.startedClient(channel: channel) {
            await events.append($0)
        }
        channel.yield(.stdout(fixture.startMarker))
        #expect(await waitUntil { await client.isReady })

        async let firstClose: Void = client.close()
        async let secondClose: Void = client.close()
        channel.yield(.stdout(fixture.exitProtocol))
        channel.finishOutput()
        channel.complete(.init(exitCode: 0, signal: nil))
        _ = await (firstClose, secondClose)

        #expect(await waitUntil { await events.closedCount == 1 })
        #expect(await events.closedCount == 1)
        #expect(await channel.closeCount() <= 1)
        await #expect(throws: TmuxControlClientError.closed) {
            try await client.execute(fixture.renameSession, timeout: .seconds(1))
        }
    }
}

private struct ControlClientFixture {
    let session: TmuxSessionID
    let pane: TmuxPaneID
    let renameSession: TmuxOperation
    let killPane: TmuxOperation
    let dialect = TmuxProtocolDialect(
        commandGuardShape: .threeFields,
        snapshotCodec: .quoted
    )
    let startMarker = Data([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
    let exitProtocol = Data("%exit\n\u{1B}\\".utf8)

    var renderedRename: Data {
        TmuxControlCommandRenderer().render(renameSession).wireData
    }

    var renderedKillPane: Data {
        TmuxControlCommandRenderer().render(killPane).wireData
    }

    init() throws {
        session = try #require(TmuxSessionID(rawValue: "$1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        renameSession = .renameSession(session, to: try TmuxName("renamed"))
        killPane = .killPane(pane)
    }

    func startedClient(
        channel: ScriptedControlProcessChannel,
        eventHandler: @escaping @Sendable (TmuxControlClientEvent) async -> Void = { _ in }
    ) throws -> TmuxControlClient {
        let client = try TmuxControlClient(
            channel: channel,
            generation: 7,
            dialect: dialect,
            eventHandler: eventHandler
        )
        Task { await client.start() }
        return client
    }

    func chunks(of data: Data, splitAt rawIndexes: [Int]) -> [Data] {
        let indexes = ([0] + rawIndexes + [data.count])
            .filter { (0 ... data.count).contains($0) }
            .sorted()
        return zip(indexes, indexes.dropFirst()).compactMap { lower, upper in
            guard lower < upper else { return nil }
            return data.subdata(in: lower ..< upper)
        }
    }
}

private actor ControlClientEventRecorder {
    private var events: [TmuxControlClientEvent] = []

    var closedCount: Int {
        events.count { event in
            if case .closed = event { return true }
            return false
        }
    }

    func append(_ event: TmuxControlClientEvent) {
        events.append(event)
    }

    func values() -> [TmuxControlClientEvent] {
        events
    }

    func contains(_ event: TmuxControlClientEvent) -> Bool {
        events.contains(event)
    }

    func containsRecovery(generation: UInt64, hasUncertainCommand: Bool) -> Bool {
        events.contains { event in
            guard case let .reconciliationRequired(candidateGeneration, uncertain) = event else {
                return false
            }
            return candidateGeneration == generation
                && (uncertain != nil) == hasUncertainCommand
        }
    }
}

private enum TestControlChannelError: Error {
    case lost
}

private final class ScriptedControlProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>

    private let outputContinuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let state = ScriptedControlProcessState()

    init() {
        (output, outputContinuation) = AsyncThrowingStream.makeStream()
    }

    func yield(_ output: RemoteProcessOutput) {
        outputContinuation.yield(output)
    }

    func finishOutput() {
        outputContinuation.finish()
    }

    func failOutput(_ error: any Error) {
        outputContinuation.finish(throwing: error)
    }

    func complete(_ exit: RemoteProcessExit) {
        Task { await state.complete(exit) }
    }

    func write(_ data: Data) async throws {
        try await state.write(data)
    }

    func resize(_ size: TermSize) async throws {}

    func result() async throws -> RemoteProcessExit {
        try await state.result()
    }

    func close() async {
        outputContinuation.finish()
        await state.close()
    }

    func recordedWrites() async -> [Data] {
        await state.writes
    }

    func closeCount() async -> Int {
        await state.closeCount
    }
}

private actor ScriptedControlProcessState {
    private enum Completion {
        case exit(RemoteProcessExit)
        case closed
    }

    private var completion: Completion?
    private var resultWaiters: [CheckedContinuation<RemoteProcessExit, Error>] = []
    private(set) var writes: [Data] = []
    private(set) var closeCount = 0

    func write(_ data: Data) throws {
        guard completion == nil else { throw SSHError.channelClosed }
        writes.append(data)
    }

    func result() async throws -> RemoteProcessExit {
        if let completion { return try resolve(completion) }
        return try await withCheckedThrowingContinuation { continuation in
            resultWaiters.append(continuation)
        }
    }

    func complete(_ exit: RemoteProcessExit) {
        guard completion == nil else { return }
        completion = .exit(exit)
        resumeWaiters()
    }

    func close() {
        guard completion == nil else { return }
        closeCount += 1
        completion = .closed
        resumeWaiters()
    }

    private func resumeWaiters() {
        guard let completion else { return }
        let waiters = resultWaiters
        resultWaiters.removeAll()
        for waiter in waiters {
            switch completion {
            case let .exit(exit):
                waiter.resume(returning: exit)
            case .closed:
                waiter.resume(throwing: SSHError.channelClosed)
            }
        }
    }

    private func resolve(_ completion: Completion) throws -> RemoteProcessExit {
        switch completion {
        case let .exit(exit):
            exit
        case .closed:
            throw SSHError.channelClosed
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
