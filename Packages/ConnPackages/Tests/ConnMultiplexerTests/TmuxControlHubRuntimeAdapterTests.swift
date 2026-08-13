import ConnKit
@testable import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux control hub runtime adapter")
struct TmuxControlHubRuntimeAdapterTests {
    @Test("an exact ready Control client wins and no one-shot fallback follows its errors")
    func routesReadyControlWithoutFallback() async throws {
        let fixture = try RuntimeAdapterFixture()
        let control = RecordingControlExecutor(result: .success(.init(
            scope: fixture.scope,
            request: fixture.request,
            output: [Data("control".utf8)]
        )))
        let locator = RecordingControlLocator(executor: control)
        let oneShot = RecordingOneShotExecutor(result: .success(.init(
            scope: fixture.scope,
            operation: fixture.operation,
            output: Data("one-shot".utf8)
        )))
        let adapter = fixture.adapter(locator: locator, oneShot: oneShot)

        let receipt = try await adapter.execute(
            fixture.request,
            timeout: .seconds(1),
            identities: []
        )
        #expect(receipt.output == [Data("control".utf8)])
        #expect(receipt.reconciliationSnapshot == nil)
        #expect(await locator.requestCount == 1)
        #expect(await control.executionCount == 1)
        #expect(await oneShot.executionCount == 0)

        let failingControl = RecordingControlExecutor(
            result: .failure(.controlTransportLost)
        )
        let failingLocator = RecordingControlLocator(executor: failingControl)
        let fallback = RecordingOneShotExecutor(result: .success(.init(
            scope: fixture.scope,
            operation: fixture.operation,
            output: Data()
        )))
        let failingAdapter = fixture.adapter(locator: failingLocator, oneShot: fallback)
        await #expect(throws: RuntimeAdapterTestError.controlTransportLost) {
            try await failingAdapter.execute(
                fixture.request,
                timeout: .seconds(1),
                identities: []
            )
        }
        #expect(await failingControl.executionCount == 1)
        #expect(await fallback.executionCount == 0)
    }

    @Test("one-shot success requires and installs one exact post-operation snapshot")
    func reconcilesOneShotBeforeHubCompletion() async throws {
        let fixture = try RuntimeAdapterFixture()
        let locator = RecordingControlLocator(executor: nil)
        let oneShot = RecordingOneShotExecutor(result: .success(.init(
            scope: fixture.scope,
            operation: fixture.operation,
            output: Data("@2\n".utf8)
        )))
        let snapshots = RecordingRuntimeSnapshotLoader(
            snapshots: [try fixture.snapshot(name: "after-one-shot")]
        )
        let adapter = fixture.adapter(
            locator: locator,
            oneShot: oneShot,
            snapshots: snapshots
        )
        let hub = try TmuxControlHub(
            scope: fixture.scope,
            initialSnapshot: try fixture.snapshot(name: "before"),
            adapter: adapter
        )

        let receipt = try await hub.execute(fixture.request, timeout: .seconds(1))

        #expect(receipt.output == [Data("@2".utf8)])
        #expect(receipt.reconciliationSnapshot?.sessions[fixture.session]?.name == "after-one-shot")
        #expect(await hub.currentSnapshot?.sessions[fixture.session]?.name == "after-one-shot")
        #expect(await locator.requestCount == 1)
        #expect(await oneShot.executionCount == 1)
        #expect(await snapshots.requestCount == 1)
        #expect(await snapshots.reasons == [.operationCompleted(fixture.operation)])
    }

    @Test("a stale generation is rejected before any runtime route")
    func rejectsStaleGenerationBeforeRouting() async throws {
        let fixture = try RuntimeAdapterFixture()
        let locator = RecordingControlLocator(executor: nil)
        let oneShot = RecordingOneShotExecutor(result: .success(.init(
            scope: fixture.scope,
            operation: fixture.operation,
            output: Data()
        )))
        let adapter = fixture.adapter(locator: locator, oneShot: oneShot)
        let staleScope = try fixture.scope(generation: 6)
        let staleRequest = TmuxOperationRequest(
            scope: staleScope,
            operation: fixture.operation
        )

        await #expect(throws: TmuxControlHubRuntimeAdapterError.staleGeneration(
            current: 7,
            requested: 6
        )) {
            try await adapter.execute(
                staleRequest,
                timeout: .seconds(1),
                identities: []
            )
        }
        #expect(await locator.requestCount == 0)
        #expect(await oneShot.executionCount == 0)
    }

    @Test("catalog snapshots preserve reason and verified interactive identities")
    func delegatesSnapshotContext() async throws {
        let fixture = try RuntimeAdapterFixture()
        let snapshots = RecordingRuntimeSnapshotLoader(
            snapshots: [try fixture.snapshot(name: "catalog")]
        )
        let adapter = fixture.adapter(snapshots: snapshots)
        let identity = fixture.identity

        let snapshot = try await adapter.loadSnapshot(
            scope: fixture.scope,
            reason: .userRequested,
            identities: [identity]
        )

        #expect(snapshot.sessions[fixture.session]?.name == "catalog")
        #expect(await snapshots.scopes == [fixture.scope])
        #expect(await snapshots.reasons == [.userRequested])
        #expect(await snapshots.identities == [[identity]])
    }

    @Test("demands are monotonic and identity-only demand cannot request Control Mode")
    func forwardsMonotonicDemand() async throws {
        let fixture = try RuntimeAdapterFixture()
        let lifecycle = RecordingRuntimeLifecycle()
        let adapter = fixture.adapter(lifecycle: lifecycle)
        let identityOnly = TmuxControlHubDemand(
            sequence: 1,
            scope: fixture.scope,
            observationTargets: [],
            identities: [fixture.identity],
            hasPendingOperations: false,
            isInvalidated: false
        )
        let observing = TmuxControlHubDemand(
            sequence: 3,
            scope: try fixture.scope(generation: 8),
            observationTargets: [.catalog],
            identities: [fixture.identity],
            hasPendingOperations: false,
            isInvalidated: false
        )
        let late = TmuxControlHubDemand(
            sequence: 2,
            scope: fixture.scope,
            observationTargets: [.catalog],
            identities: [],
            hasPendingOperations: true,
            isInvalidated: false
        )

        await adapter.demandChanged(identityOnly)
        await adapter.demandChanged(observing)
        await adapter.demandChanged(late)

        let demands = await lifecycle.demands
        #expect(demands.map(\.sequence) == [1, 3])
        #expect(!demands[0].requiresControlRuntime)
        #expect(demands[1].requiresControlRuntime)
    }
}

private struct RuntimeAdapterFixture: Sendable {
    let token: TmuxServerInstanceToken
    let scope: TmuxOperationScope
    let session: TmuxSessionID
    let window: TmuxWindowID
    let pane: TmuxPaneID
    let operation: TmuxOperation
    let request: TmuxOperationRequest

    init() throws {
        token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
        session = try #require(TmuxSessionID(rawValue: "$1"))
        window = try #require(TmuxWindowID(rawValue: "@1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        scope = try Self.makeScope(token: token, generation: 7)
        operation = .renameSession(session, to: try TmuxName("renamed"))
        request = .init(scope: scope, operation: operation)
    }

    var identity: TmuxControlInteractiveIdentity {
        .init(
            attachmentID: "attachment-1",
            clientID: .init(targetName: "/dev/pts/1", processID: 501, createdAt: 1_001),
            requestedSessionID: session
        )
    }

    func scope(generation: UInt64) throws -> TmuxOperationScope {
        try Self.makeScope(token: token, generation: generation)
    }

    func adapter(
        locator: any TmuxReadyControlClientLocating = RecordingControlLocator(executor: nil),
        oneShot: any TmuxOneShotOperationExecuting = RecordingOneShotExecutor(
            result: .failure(.unexpectedRoute)
        ),
        snapshots: any TmuxControlHubSnapshotLoading = RecordingRuntimeSnapshotLoader(
            snapshots: []
        ),
        lifecycle: any TmuxControlRuntimeLifecycleDriving = RecordingRuntimeLifecycle()
    ) -> TmuxControlHubRuntimeAdapter {
        TmuxControlHubRuntimeAdapter(
            initialScope: scope,
            controlClients: locator,
            oneShot: oneShot,
            snapshots: snapshots,
            lifecycle: lifecycle
        )
    }

    func snapshot(name: String) throws -> TmuxServerSnapshot {
        try TmuxServerSnapshot(
            instance: .init(token: token, version: "3.5a"),
            sessions: [session: .init(
                id: session,
                name: name,
                groupName: nil,
                currentWindowID: window
            )],
            sessionGroups: [:],
            windows: [window: .init(
                id: window,
                name: "window",
                layout: nil,
                isZoomed: false,
                activePaneID: pane
            )],
            panes: [pane: .init(
                id: pane,
                windowID: window,
                index: 0,
                title: .unavailable,
                currentCommand: .unavailable,
                currentPath: .unavailable,
                size: .init(cols: 80, rows: 24),
                isDead: false
            )],
            windowLinks: [.init(sessionID: session, windowID: window, index: 0)],
            clients: [:],
            observedAt: Date(timeIntervalSince1970: 100),
            revision: 0,
            impactRevision: 0
        )
    }

    private static func makeScope(
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

private enum RuntimeAdapterTestError: Error {
    case controlTransportLost
    case unexpectedRoute
}

private actor RecordingControlExecutor: TmuxControlOperationExecuting {
    private let result: Result<TmuxControlOperationExecution, RuntimeAdapterTestError>
    private(set) var executionCount = 0

    init(result: Result<TmuxControlOperationExecution, RuntimeAdapterTestError>) {
        self.result = result
    }

    func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration
    ) async throws -> TmuxControlOperationExecution {
        executionCount += 1
        return try result.get()
    }
}

private actor RecordingControlLocator: TmuxReadyControlClientLocating {
    private let executor: (any TmuxControlOperationExecuting)?
    private(set) var requestCount = 0

    init(executor: (any TmuxControlOperationExecuting)?) {
        self.executor = executor
    }

    func readyExecutor(
        for request: TmuxOperationRequest
    ) async throws -> (any TmuxControlOperationExecuting)? {
        requestCount += 1
        return executor
    }
}

private actor RecordingOneShotExecutor: TmuxOneShotOperationExecuting {
    private let result: Result<TmuxOneShotOperationResult, RuntimeAdapterTestError>
    private(set) var executionCount = 0

    init(result: Result<TmuxOneShotOperationResult, RuntimeAdapterTestError>) {
        self.result = result
    }

    func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration
    ) async throws -> TmuxOneShotOperationResult {
        executionCount += 1
        return try result.get()
    }
}

private actor RecordingRuntimeSnapshotLoader: TmuxControlHubSnapshotLoading {
    private var snapshots: [TmuxServerSnapshot]
    private(set) var scopes: [TmuxOperationScope] = []
    private(set) var reasons: [TmuxControlHubSnapshotReason] = []
    private(set) var identities: [Set<TmuxControlInteractiveIdentity>] = []

    init(snapshots: [TmuxServerSnapshot]) {
        self.snapshots = snapshots
    }

    var requestCount: Int { scopes.count }

    func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot {
        scopes.append(scope)
        reasons.append(reason)
        self.identities.append(identities)
        return snapshots.removeFirst()
    }
}

private actor RecordingRuntimeLifecycle: TmuxControlRuntimeLifecycleDriving {
    private(set) var demands: [TmuxControlHubDemand] = []

    func demandChanged(_ demand: TmuxControlHubDemand) async {
        demands.append(demand)
    }
}
