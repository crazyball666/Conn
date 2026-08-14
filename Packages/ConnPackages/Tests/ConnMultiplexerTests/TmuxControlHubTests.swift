import ConnKit
import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux control hub")
struct TmuxControlHubTests {
    @Test("identity leases preserve ownership without keeping control alive")
    func separatesIdentityAndObservationLifetimes() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter()
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )

        let identity = TmuxControlInteractiveIdentity(
            attachmentID: "attachment-1",
            clientID: TmuxClientID(
                targetName: "/dev/pts/1",
                processID: 101,
                createdAt: 1_000
            ),
            requestedSessionID: fixture.session
        )
        let identityLease = try await hub.acquireIdentityLease(identity)
        var status = await hub.status
        #expect(status.identityLeaseCount == 1)
        #expect(status.observationLeaseCount == 0)
        #expect(!status.requiresControlRuntime)
        #expect(!status.canEvict)

        let observation = try await hub.acquireObservationLease(.session(fixture.session))
        var iterator = observation.snapshots.makeAsyncIterator()
        #expect(await iterator.next()?.sessions[fixture.session]?.name == "one")
        status = await hub.status
        #expect(status.identityLeaseCount == 1)
        #expect(status.observationLeaseCount == 1)
        #expect(status.requiresControlRuntime)
        #expect(await waitUntil {
            await adapter.latestDemand()?.observationTargets == [.session(fixture.session)]
        })

        await hub.releaseLease(identityLease)
        status = await hub.status
        #expect(status.identityLeaseCount == 0)
        #expect(status.requiresControlRuntime)

        await hub.releaseLease(observation.lease)
        #expect(await iterator.next() == nil)
        status = await hub.status
        #expect(status.observationLeaseCount == 0)
        #expect(!status.requiresControlRuntime)
        #expect(status.canEvict)
    }

    @Test("snapshots stay monotonic and stale generations never reach observers")
    func ordersSnapshotsAndDiscardsOldGenerations() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter()
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )
        let observation = try await hub.acquireObservationLease(.catalog)
        var iterator = observation.snapshots.makeAsyncIterator()
        let initial = try #require(await iterator.next())

        let stale = try await hub.apply(fixture.envelope(
            generation: 6,
            event: .sessionRenamed(fixture.session, name: "stale")
        ))
        #expect(stale == .discardedStaleGeneration)
        #expect(await hub.currentSnapshot?.sessions[fixture.session]?.name == "one")

        let applied = try await hub.apply(fixture.envelope(
            generation: 7,
            event: .sessionRenamed(fixture.session, name: "live")
        ))
        #expect(applied == .applied)
        let live = try #require(await iterator.next())

        let installed = try await hub.reconcile(
            with: try fixture.snapshot(name: "generation-eight", observedAt: fixture.later),
            generation: 8
        )
        #expect(installed == .applied)
        let generationEight = try #require(await iterator.next())

        #expect([initial.revision, live.revision, generationEight.revision] == [0, 1, 2])
        #expect(live.sessions[fixture.session]?.name == "live")
        #expect(generationEight.sessions[fixture.session]?.name == "generation-eight")
        #expect(await hub.currentScope.generation == 8)

        let late = try await hub.apply(fixture.envelope(
            generation: 7,
            event: .sessionRenamed(fixture.session, name: "late")
        ))
        #expect(late == .discardedStaleGeneration)
        #expect(await hub.currentSnapshot?.sessions[fixture.session]?.name == "generation-eight")
        await hub.releaseLease(observation.lease)
    }

    @Test("reconciliation is loaded through the adapter only for current events")
    func loadsSnapshotsAtTheAdapterSeam() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter()
        await adapter.enqueueSnapshot(
            try fixture.snapshot(name: "from-adapter", observedAt: fixture.later)
        )
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )

        let reduction = try await hub.apply(fixture.envelope(
            event: .sessionsChanged
        ))
        #expect(reduction == .applied)
        #expect(await hub.currentSnapshot?.sessions[fixture.session]?.name == "from-adapter")
        #expect(await adapter.snapshotRequestCount == 1)

        let stale = try await hub.apply(fixture.envelope(
            generation: 6,
            event: .sessionsChanged
        ))
        #expect(stale == .discardedStaleGeneration)
        #expect(await adapter.snapshotRequestCount == 1)
    }

    @Test("Control Mode notification drives Hub reconciliation and observer snapshots")
    func controlNotificationReconcilesObservers() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter()
        await adapter.enqueueSnapshot(
            try fixture.snapshot(name: "renamed", observedAt: fixture.later)
        )
        let (events, continuation) = AsyncStream<TmuxControlClientEvent>.makeStream()
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )
        await hub.startEventStream(events)
        let observation = try await hub.acquireObservationLease(.catalog)
        var iterator = observation.snapshots.makeAsyncIterator()
        _ = try #require(await iterator.next())

        continuation.yield(.notification(
            generation: 7,
            .known(.sessionsChanged, payload: Data())
        ))

        #expect(await waitUntil { await adapter.snapshotRequestCount == 1 })
        let updated = try #require(await iterator.next())
        #expect(updated.sessions[fixture.session]?.name == "renamed")

        continuation.finish()
        await hub.releaseLease(observation.lease)
        await hub.close()
    }

    @Test("format subscription updates pane metadata live without a snapshot reload")
    func formatSubscriptionUpdatesPaneMetadata() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter()
        await adapter.enqueueSnapshot(try fixture.snapshot(observedAt: fixture.later))
        let (events, continuation) = AsyncStream<TmuxControlClientEvent>.makeStream()
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.later }
        )
        await hub.startEventStream(events)
        let observation = try await hub.acquireObservationLease(.catalog)
        var iterator = observation.snapshots.makeAsyncIterator()
        _ = try #require(await iterator.next())

        continuation.yield(.notification(
            generation: 7,
            .known(
                .subscriptionChanged,
                payload: Data("__conn_pane_title__ $1 @1 0 %1 : live\\040title".utf8)
            )
        ))

        #expect(await waitUntil {
            await hub.currentSnapshot?.panes[fixture.pane]?.title.value == "live title"
        })
        let updated = try #require(await hub.currentSnapshot)
        #expect(updated.panes[fixture.pane]?.title == TmuxObservedValue(
            value: "live title",
            freshness: .liveSubscription(observedAt: fixture.later)
        ))
        #expect(await adapter.snapshotRequestCount == 0)

        continuation.finish()
        await hub.releaseLease(observation.lease)
        await hub.close()
    }

    @Test("an older concurrent refresh cannot overwrite a newer completed snapshot")
    func discardsOutOfOrderRefreshResults() async throws {
        let fixture = try ControlHubFixture()
        let adapter = OutOfOrderSnapshotAdapter()
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )

        let older = Task { try await hub.refresh() }
        #expect(await waitUntil { await adapter.requestCount == 1 })
        let newer = Task { try await hub.refresh() }
        #expect(await waitUntil { await adapter.requestCount == 2 })

        await adapter.complete(
            request: 1,
            with: try fixture.snapshot(name: "newer", observedAt: fixture.later)
        )
        #expect(try await newer.value == .applied)
        await adapter.complete(
            request: 0,
            with: try fixture.snapshot(
                name: "older",
                observedAt: fixture.now.addingTimeInterval(1)
            )
        )
        #expect(try await older.value == .discardedStaleGeneration)
        #expect(await hub.currentSnapshot?.sessions[fixture.session]?.name == "newer")
    }

    @Test("operations queue fairly and pending work alone keeps control alive")
    func serializesOperations() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter(blockOperations: true)
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )
        let firstRequest = try fixture.renameRequest("first")
        let secondRequest = TmuxOperationRequest(
            scope: try fixture.scope(),
            operation: .setPaneZoom(fixture.pane, zoomed: true)
        )

        let first = Task {
            try await hub.execute(firstRequest, timeout: .seconds(1))
        }
        #expect(await waitUntil { await adapter.executionCount == 1 })
        let second = Task {
            try await hub.execute(secondRequest, timeout: .seconds(1))
        }
        #expect(await waitUntil { await hub.status.pendingOperationCount == 2 })
        #expect(await adapter.executionCount == 1)
        #expect(await hub.status.requiresControlRuntime)

        await adapter.releaseNextOperation()
        #expect(try await first.value.request == firstRequest)
        #expect(await waitUntil { await adapter.executionCount == 2 })
        await adapter.releaseNextOperation()
        #expect(try await second.value.request == secondRequest)
        #expect(await waitUntil { await hub.status.pendingOperationCount == 0 })
        let finalStatus = await hub.status
        #expect(!finalStatus.requiresControlRuntime)
        #expect(await adapter.executedRequests == [firstRequest, secondRequest])
    }

    @Test("cancelling queued work removes it without dispatching the mutation")
    func cancelsQueuedOperationBeforeDispatch() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter(blockOperations: true)
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )
        let firstRequest = try fixture.renameRequest("first")
        let cancelledRequest = try fixture.renameRequest("cancelled")
        let first = Task {
            try await hub.execute(firstRequest, timeout: .seconds(1))
        }
        #expect(await waitUntil { await adapter.executionCount == 1 })
        let cancelled = Task {
            try await hub.execute(cancelledRequest, timeout: .seconds(1))
        }
        #expect(await waitUntil { await hub.status.pendingOperationCount == 2 })

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await hub.status.pendingOperationCount == 1)

        await adapter.releaseNextOperation()
        _ = try await first.value
        #expect(await waitUntil { await hub.status.pendingOperationCount == 0 })
        #expect(await adapter.executedRequests == [firstRequest])
    }

    @Test("connection or profile replacement invalidates queued work and quarantines an old result")
    func invalidatesRuntimeScope() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter(blockOperations: true)
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )
        let firstRequest = try fixture.renameRequest("first")
        let queuedRequest = try fixture.renameRequest("queued")
        let first = Task {
            try await hub.execute(firstRequest, timeout: .seconds(1))
        }
        #expect(await waitUntil { await adapter.executionCount == 1 })
        let queued = Task {
            try await hub.execute(queuedRequest, timeout: .seconds(1))
        }
        #expect(await waitUntil { await hub.status.pendingOperationCount == 2 })

        let changed = await hub.invalidateIfRuntimeChanged(
            connectionIdentity: fixture.connectionIdentity(hostID: "host-2"),
            profileID: "profile-1"
        )
        #expect(changed)
        await #expect(throws: TmuxControlHubError.invalidated(.connectionIdentityChanged)) {
            try await queued.value
        }
        #expect(await adapter.executionCount == 1)

        await adapter.releaseNextOperation()
        await #expect(throws: TmuxControlHubError.operationOutcomeUnknown(firstRequest)) {
            try await first.value
        }
        await #expect(throws: TmuxControlHubError.invalidated(.connectionIdentityChanged)) {
            try await hub.execute(firstRequest, timeout: .seconds(1))
        }

        let profileHub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: ScriptedControlHubAdapter(),
            clock: { fixture.now }
        )
        #expect(await profileHub.invalidateIfRuntimeChanged(
            connectionIdentity: fixture.connectionIdentity(),
            profileID: "profile-2"
        ))
        await #expect(throws: TmuxControlHubError.invalidated(.profileChanged)) {
            try await profileHub.execute(firstRequest, timeout: .seconds(1))
        }
    }

    @Test("a newer generation discards an in-flight old-generation result")
    func discardsOldGenerationOperationResults() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter(blockOperations: true)
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )
        let request = try fixture.renameRequest("old-generation")
        let operation = Task {
            try await hub.execute(request, timeout: .seconds(1))
        }
        #expect(await waitUntil { await adapter.executionCount == 1 })

        _ = try await hub.reconcile(
            with: try fixture.snapshot(name: "new-generation", observedAt: fixture.later),
            generation: 8
        )
        await adapter.releaseNextOperation()
        await #expect(throws: TmuxControlHubError.operationOutcomeUnknown(request)) {
            try await operation.value
        }
        #expect(await hub.currentScope.generation == 8)
    }

    @Test("a different server instance invalidates the hub and hides all old entity IDs")
    func invalidatesChangedServerInstance() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter()
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )
        let observation = try await hub.acquireObservationLease(.catalog)
        var iterator = observation.snapshots.makeAsyncIterator()
        _ = await iterator.next()
        let replacementToken = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 200,
            serverStartTime: 300
        )

        let reduction = try await hub.reconcile(
            with: fixture.snapshot(token: replacementToken),
            generation: 8
        )
        #expect(reduction == .serverInstanceChanged)
        #expect(await hub.currentSnapshot == nil)
        #expect(await hub.status.invalidationReason == .serverInstanceChanged)
        #expect(await iterator.next() == nil)
        await #expect(throws: TmuxControlHubError.invalidated(.serverInstanceChanged)) {
            try await hub.execute(
                fixture.renameRequest("must-not-run"),
                timeout: .seconds(1)
            )
        }
        #expect(await adapter.executionCount == 0)
    }

    @Test("destructive validation and nonce consumption are atomic with queue admission")
    func consumesDestructiveNonceOnce() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter(blockOperations: true)
        for _ in 0 ..< 3 {
            await adapter.enqueueSnapshot(try fixture.snapshot(observedAt: fixture.now))
        }
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(observedAt: fixture.now),
            adapter: adapter,
            clock: { fixture.now }
        )
        let request = TmuxOperationRequest(
            scope: try fixture.scope(),
            operation: .killPane(fixture.pane)
        )
        let prepared = try await hub.prepareDestructive(request)
        let first = Task {
            try await hub.executeDestructive(
                prepared.claim,
                for: request,
                timeout: .seconds(1)
            )
        }
        #expect(await waitUntil { await adapter.executionCount == 1 })

        await #expect(throws: TmuxControlHubError.confirmationAlreadyConsumed(
            prepared.claim.nonce
        )) {
            try await hub.executeDestructive(
                prepared.claim,
                for: request,
                timeout: .seconds(1)
            )
        }
        #expect(await adapter.executionCount == 1)

        await adapter.releaseNextOperation()
        #expect(try await first.value.request == request)
        #expect(await adapter.executedRequests == [request])
    }

    @Test("non-destructive operations can preview shared impact without execution")
    func previewsSharedImpactWithoutExecution() async throws {
        let fixture = try ControlHubFixture()
        let adapter = ScriptedControlHubAdapter()
        let otherClientID = TmuxClientID(
            targetName: "/dev/pts/22",
            processID: 222,
            createdAt: 2_000
        )
        let freshSnapshot = try fixture.snapshot(clients: [
            otherClientID: TmuxClientSnapshot(
                id: otherClientID,
                sessionID: fixture.session,
                currentWindowID: fixture.window,
                activePaneID: fixture.pane,
                flags: [],
                role: .external,
                kind: .interactiveTerminal,
                sizeParticipation: .participating,
                observedAt: fixture.now
            ),
        ])
        await adapter.enqueueSnapshot(freshSnapshot)
        let hub = try TmuxControlHub(
            scope: try fixture.scope(),
            initialSnapshot: try fixture.snapshot(),
            adapter: adapter,
            clock: { fixture.now }
        )
        let request = try fixture.renameRequest("shared")

        let impact = try await hub.previewImpact(request)

        #expect(impact.affectedSessionIDs == [fixture.session])
        #expect(impact.otherAffectedClientIDs == [otherClientID])
        #expect(impact.sharedStateEffects == [.sessionIdentity])
        #expect(await adapter.executionCount == 0)
        #expect(await adapter.snapshotRequestCount == 1)
    }
}

private actor ScriptedControlHubAdapter: TmuxControlHubAdapter {
    private var snapshots: [TmuxServerSnapshot] = []
    private var demands: [TmuxControlHubDemand] = []
    private var executions: [TmuxOperationRequest] = []
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private let blockOperations: Bool

    init(blockOperations: Bool = false) {
        self.blockOperations = blockOperations
    }

    var snapshotRequestCount: Int { demandsSnapshotRequestCount }
    private var demandsSnapshotRequestCount = 0
    var executionCount: Int { executions.count }
    var executedRequests: [TmuxOperationRequest] { executions }

    func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxControlHubOperationReceipt {
        executions.append(request)
        if blockOperations {
            await withCheckedContinuation { continuation in
                operationWaiters.append(continuation)
            }
        }
        return TmuxControlHubOperationReceipt(
            request: request,
            output: [Data("ok".utf8)]
        )
    }

    func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot {
        demandsSnapshotRequestCount += 1
        return snapshots.removeFirst()
    }

    func demandChanged(_ demand: TmuxControlHubDemand) async {
        demands.append(demand)
    }

    func enqueueSnapshot(_ snapshot: TmuxServerSnapshot) {
        snapshots.append(snapshot)
    }

    func releaseNextOperation() {
        guard !operationWaiters.isEmpty else { return }
        operationWaiters.removeFirst().resume()
    }

    func latestDemand() -> TmuxControlHubDemand? {
        demands.last
    }
}

private actor OutOfOrderSnapshotAdapter: TmuxControlHubAdapter {
    private var nextRequest = 0
    private var snapshotWaiters: [
        Int: CheckedContinuation<TmuxServerSnapshot, any Error>
    ] = [:]

    var requestCount: Int { nextRequest }

    func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxControlHubOperationReceipt {
        TmuxControlHubOperationReceipt(request: request, output: [])
    }

    func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot {
        let request = nextRequest
        nextRequest += 1
        return try await withCheckedThrowingContinuation { continuation in
            snapshotWaiters[request] = continuation
        }
    }

    func demandChanged(_ demand: TmuxControlHubDemand) async {}

    func complete(request: Int, with snapshot: TmuxServerSnapshot) {
        snapshotWaiters.removeValue(forKey: request)?.resume(returning: snapshot)
    }
}

private struct ControlHubFixture: Sendable {
    let session: TmuxSessionID
    let window: TmuxWindowID
    let pane: TmuxPaneID
    let token: TmuxServerInstanceToken
    let now = Date(timeIntervalSince1970: 110)
    let later = Date(timeIntervalSince1970: 120)

    init() throws {
        session = try #require(TmuxSessionID(rawValue: "$1"))
        window = try #require(TmuxWindowID(rawValue: "@1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
    }

    func connectionIdentity(hostID: String = "host-1") -> SSHConnectionIdentity {
        SSHConnectionIdentity(host: Host(
            id: hostID,
            name: "Server",
            address: "server.example",
            username: "root"
        ))
    }

    func scope(generation: UInt64 = 7) throws -> TmuxOperationScope {
        try TmuxOperationScope(
            connectionIdentity: connectionIdentity(),
            profileID: "profile-1",
            instanceToken: token,
            generation: generation
        )
    }

    func renameRequest(_ name: String) throws -> TmuxOperationRequest {
        TmuxOperationRequest(
            scope: try scope(),
            operation: .renameSession(session, to: try TmuxName(name))
        )
    }

    func envelope(
        generation: UInt64 = 7,
        event: TmuxStateEvent
    ) -> TmuxStateEventEnvelope {
        .init(
            generation: generation,
            serverToken: token,
            observedAt: later,
            event: event
        )
    }

    func snapshot(
        token: TmuxServerInstanceToken? = nil,
        name: String = "one",
        observedAt: Date = Date(timeIntervalSince1970: 100),
        clients: [TmuxClientID: TmuxClientSnapshot] = [:]
    ) throws -> TmuxServerSnapshot {
        try TmuxServerSnapshot(
            instance: .init(token: token ?? self.token, version: "tmux 3.5a"),
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
            clients: clients,
            observedAt: observedAt,
            revision: 0,
            impactRevision: 0
        )
    }
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
