import ConnKit
@testable import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux snapshot loader")
struct TmuxSnapshotLoaderTests {
    @Test("quoted snapshot loads one framed generation and preserves escaped line boundaries")
    func loadsQuotedSnapshot() async throws {
        let fixture = try SnapshotLoaderFixture()
        let plan = try fixture.renderer.renderPlan(codec: .quoted, nonce: fixture.nonce)
        let step = try #require(plan.steps.first)
        let executor = ScriptedReadOnlyExecutor(results: [
            .init(scope: fixture.scope, output: fixture.quotedOutput(step: step)),
        ])
        let loader = fixture.loader(executor: executor)

        let snapshot = try await loader.load(
            scope: fixture.scope,
            dialect: fixture.quotedDialect,
            identities: [fixture.interactiveIdentity],
            controlClientID: nil,
            timeout: .seconds(1)
        )

        #expect(snapshot.instance.token == fixture.token)
        #expect(snapshot.panes[fixture.pane]?.title.value == "editor\nprimary")
        #expect(snapshot.panes[fixture.pane]?.title.freshness == .snapshot(
            observedAt: fixture.observedAt
        ))
        #expect(snapshot.clients[fixture.interactiveClientID]?.role == .connInteractive(
            attachmentID: "attachment-1"
        ))
        #expect(await executor.requestCount == 1)
        #expect(await executor.requestedScopes == [fixture.scope])
    }

    @Test("legacy snapshot expands typed indexes into independent text reads before final identity")
    func loadsLegacySnapshot() async throws {
        let fixture = try SnapshotLoaderFixture()
        let executor = ScriptedReadOnlyExecutor(
            results: try fixture.legacyResults(finalPID: "100")
        )
        let loader = fixture.loader(executor: executor)

        let snapshot = try await loader.load(
            scope: fixture.scope,
            dialect: fixture.legacyDialect,
            identities: [],
            controlClientID: nil,
            timeout: .seconds(1)
        )

        #expect(snapshot.sessions[fixture.session]?.name == "alpha")
        #expect(snapshot.sessions[fixture.session]?.groupName == nil)
        #expect(snapshot.windows[fixture.window]?.name == "editor")
        #expect(snapshot.panes[fixture.pane]?.title.value == "legacy\nline")
        #expect(snapshot.panes[fixture.pane]?.title.freshness == .snapshot(
            observedAt: fixture.observedAt
        ))
        #expect(await executor.requestCount == 17)

        let requests = await executor.requests
        let finalIdentityIndex = try #require(requests.lastIndex {
            String(decoding: $0.wireData, as: UTF8.self).contains("#{socket_path}")
        })
        let panePathIndex = try #require(requests.firstIndex {
            String(decoding: $0.wireData, as: UTF8.self).contains("#{pane_current_path}")
        })
        #expect(finalIdentityIndex > panePathIndex)
    }

    @Test("actual execution scope and legacy final server identity must remain exact")
    func rejectsGenerationAndIdentityChanges() async throws {
        let fixture = try SnapshotLoaderFixture()
        let plan = try fixture.renderer.renderPlan(codec: .quoted, nonce: fixture.nonce)
        let step = try #require(plan.steps.first)
        let staleScope = try fixture.makeScope(generation: 6)
        let staleExecutor = ScriptedReadOnlyExecutor(results: [
            .init(scope: staleScope, output: fixture.quotedOutput(step: step)),
        ])
        let staleLoader = fixture.loader(executor: staleExecutor)
        await #expect(throws: TmuxSnapshotLoaderError.scopeMismatch(
            expected: fixture.scope,
            actual: staleScope
        )) {
            try await staleLoader.load(
                scope: fixture.scope,
                dialect: fixture.quotedDialect,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(1)
            )
        }

        let quotedChangedExecutor = ScriptedReadOnlyExecutor(results: [
            .init(
                scope: fixture.scope,
                output: fixture.quotedOutput(step: step, finalPID: "101")
            ),
        ])
        let quotedChangedLoader = fixture.loader(executor: quotedChangedExecutor)
        await #expect(throws: TmuxSnapshotAssemblerError.serverIdentityMismatch) {
            try await quotedChangedLoader.load(
                scope: fixture.scope,
                dialect: fixture.quotedDialect,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(1)
            )
        }

        let changedExecutor = ScriptedReadOnlyExecutor(
            results: try fixture.legacyResults(finalPID: "101")
        )
        let changedLoader = fixture.loader(executor: changedExecutor)
        await #expect(throws: TmuxSnapshotAssemblerError.serverIdentityMismatch) {
            try await changedLoader.load(
                scope: fixture.scope,
                dialect: fixture.legacyDialect,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(1)
            )
        }
    }

    @Test("same-scope loads serialize while a newer generation invalidates an older result")
    func serializesAndInvalidatesLoads() async throws {
        let fixture = try SnapshotLoaderFixture()
        let plan = try fixture.renderer.renderPlan(codec: .quoted, nonce: fixture.nonce)
        let step = try #require(plan.steps.first)
        let output = fixture.quotedOutput(step: step, includeClient: false)
        let executor = BlockingReadOnlyExecutor(output: output)
        let loader = fixture.loader(executor: executor)

        let first = Task {
            try await loader.load(
                scope: fixture.scope,
                dialect: fixture.quotedDialect,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(1)
            )
        }
        #expect(await waitUntil { await executor.requestCount == 1 })
        let second = Task {
            try await loader.load(
                scope: fixture.scope,
                dialect: fixture.quotedDialect,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(1)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await executor.requestCount == 1)
        await executor.completeNext(scope: fixture.scope)
        _ = try await first.value
        #expect(await waitUntil { await executor.requestCount == 2 })
        await executor.completeNext(scope: fixture.scope)
        _ = try await second.value

        let oldScope = fixture.scope
        let newScope = try fixture.makeScope(generation: 8)
        let old = Task {
            try await loader.load(
                scope: oldScope,
                dialect: fixture.quotedDialect,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(1)
            )
        }
        #expect(await waitUntil { await executor.requestCount == 3 })
        let newer = Task {
            try await loader.load(
                scope: newScope,
                dialect: fixture.quotedDialect,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(1)
            )
        }
        #expect(await waitUntil { await executor.requestCount == 4 })
        await executor.completeNext(scope: oldScope)
        await #expect(throws: TmuxSnapshotLoaderError.staleGeneration) {
            try await old.value
        }
        await executor.completeNext(scope: newScope)
        #expect(try await newer.value.instance.token == fixture.token)
    }
}

private struct SnapshotLoaderFixture: Sendable {
    let nonce: TmuxInvocationNonce
    let renderer = TmuxSnapshotQueryRenderer()
    let token: TmuxServerInstanceToken
    let scope: TmuxOperationScope
    let session: TmuxSessionID
    let window: TmuxWindowID
    let pane: TmuxPaneID
    let interactiveClientID: TmuxClientID
    let observedAt = Date(timeIntervalSince1970: 700)
    let quotedDialect = TmuxProtocolDialect(
        commandGuardShape: .threeFields,
        snapshotCodec: .quoted
    )
    let legacyDialect = TmuxProtocolDialect(
        commandGuardShape: .twoFields,
        snapshotCodec: .legacyPerField
    )

    init() throws {
        nonce = try TmuxInvocationNonce("loader-1")
        token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
        session = try #require(TmuxSessionID(rawValue: "$1"))
        window = try #require(TmuxWindowID(rawValue: "@1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        interactiveClientID = .init(
            targetName: "/dev/ttys001",
            processID: 501,
            createdAt: 1001
        )
        scope = try Self.scope(token: token, generation: 7)
    }

    var interactiveIdentity: TmuxControlInteractiveIdentity {
        .init(
            attachmentID: "attachment-1",
            clientID: interactiveClientID,
            requestedSessionID: session
        )
    }

    func makeScope(generation: UInt64) throws -> TmuxOperationScope {
        try Self.scope(token: token, generation: generation)
    }

    func loader(
        executor: any TmuxReadOnlyCommandExecuting
    ) -> TmuxSnapshotLoader {
        TmuxSnapshotLoader(
            executor: executor,
            nonceFactory: { nonce },
            clock: { observedAt }
        )
    }

    func quotedOutput(
        step: TmuxSnapshotQueryStep,
        includeClient: Bool = true,
        finalPID: String = "100"
    ) -> [Data] {
        var records: [TmuxSnapshotSection: [Data]] = [
            .serverIdentityBefore: [line(#""/tmp/tmux/default" "100" "200" "3.5a""#)],
            .sessions: [line(#""$1" "alpha" """#)],
            .windowLinks: [line(#""$1" "@1" "0" "1""#)],
            .windows: [line(#""@1" "editor" "layout" "0""#)],
            .panes: [
                line(#""@1" "%1" "0" "editor\"#),
                line(#"primary" "nvim" "/repo" "80" "24" "0" "1""#),
            ],
            .clients: [],
            .serverIdentityAfter: [line(
                #""/tmp/tmux/default" "\#(finalPID)" "200" "3.5a""#
            )],
        ]
        if includeClient {
            records[.clients] = [line(
                #""/dev/ttys001" "/dev/ttys001" "501" "1001" "$1" "@1" "%1" "ignore-size" "0""#
            )]
        }
        return framed(step: step, records: records)
    }

    func legacyResults(finalPID: String) throws -> [TmuxReadOnlyCommandExecution] {
        let plan = try renderer.renderPlan(codec: .legacyPerField, nonce: nonce)
        let prefix = Array(plan.steps.prefix { step in
            step.frames.first?.section != .serverIdentityAfter
        })
        let suffix = Array(plan.steps.dropFirst(prefix.count))
        #expect(prefix.count == 8)
        #expect(suffix.count == 2)

        let baseLines: [[Data]] = [
            [line(#""100" "200""#)],
            [line("/tmp/tmux/default")],
            [line("3.5a")],
            [line(#""$1""#)],
            [line(#""$1" "@1" "0" "1""#)],
            [line(#""@1" "0""#)],
            [line(#""@1" "%1" "0" "80" "24" "0" "1""#)],
            [],
        ]
        var results = zip(prefix, baseLines).map { step, lines in
            TmuxReadOnlyCommandExecution(
                scope: scope,
                output: framed(step: step, records: [step.frames[0].section: lines])
            )
        }

        let fields: [(TmuxLegacySnapshotField, [Data])] = [
            (.sessionName(session), [line("alpha")]),
            (.sessionGroup(session), [line("")]),
            (.windowName(window), [line("editor")]),
            (.windowLayout(window), [line("layout")]),
            (.paneTitle(pane), [line("legacy"), line("line")]),
            (.paneCurrentCommand(pane), [line("sh")]),
            (.paneCurrentPath(pane), [line("/repo")]),
        ]
        for (field, lines) in fields {
            let step = try renderer.renderLegacyField(field, nonce: nonce)
            results.append(.init(
                scope: scope,
                output: framed(step: step, records: [step.frames[0].section: lines])
            ))
        }

        let suffixLines: [[Data]] = [
            [line(#""\#(finalPID)" "200""#)],
            [line("/tmp/tmux/default")],
        ]
        results += zip(suffix, suffixLines).map { step, lines in
            TmuxReadOnlyCommandExecution(
                scope: scope,
                output: framed(step: step, records: [step.frames[0].section: lines])
            )
        }
        return results
    }

    private static func scope(
        token: TmuxServerInstanceToken,
        generation: UInt64
    ) throws -> TmuxOperationScope {
        try TmuxOperationScope(
            connectionIdentity: SSHConnectionIdentity(host: Host(
                id: "host-1",
                name: "Server",
                address: "server.example",
                username: "root"
            )),
            profileID: "profile-1",
            instanceToken: token,
            generation: generation
        )
    }
}

private actor ScriptedReadOnlyExecutor: TmuxReadOnlyCommandExecuting {
    private var results: [TmuxReadOnlyCommandExecution]
    private(set) var requests: [TmuxControlRequest] = []
    private(set) var requestedScopes: [TmuxOperationScope] = []

    init(results: [TmuxReadOnlyCommandExecution]) {
        self.results = results
    }

    var requestCount: Int { requests.count }

    func execute(
        _ request: TmuxControlRequest,
        scope: TmuxOperationScope,
        timeout: Duration
    ) async throws -> TmuxReadOnlyCommandExecution {
        requests.append(request)
        requestedScopes.append(scope)
        return results.removeFirst()
    }
}

private actor BlockingReadOnlyExecutor: TmuxReadOnlyCommandExecuting {
    private let output: [Data]
    private var waiters: [CheckedContinuation<TmuxOperationScope, Never>] = []
    private(set) var requestCount = 0

    init(output: [Data]) {
        self.output = output
    }

    func execute(
        _ request: TmuxControlRequest,
        scope: TmuxOperationScope,
        timeout: Duration
    ) async throws -> TmuxReadOnlyCommandExecution {
        requestCount += 1
        let returnedScope = await withCheckedContinuation {
            (continuation: CheckedContinuation<TmuxOperationScope, Never>) in
            waiters.append(continuation)
        }
        return .init(scope: returnedScope, output: output)
    }

    func completeNext(scope: TmuxOperationScope) {
        waiters.removeFirst().resume(returning: scope)
    }
}

private func framed(
    step: TmuxSnapshotQueryStep,
    records: [TmuxSnapshotSection: [Data]]
) -> [Data] {
    step.frames.flatMap { frame in
        [line(frame.beginMarker)] + (records[frame.section] ?? []) + [line(frame.endMarker)]
    }
}

private func line(_ value: String) -> Data {
    Data(value.utf8)
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
