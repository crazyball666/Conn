import ConnSSH
import Foundation

package enum TmuxControlHubInvalidationReason: Sendable, Equatable {
    case connectionIdentityChanged
    case profileChanged
    case serverInstanceChanged
    case closed
}

package enum TmuxControlHubError: Error, Sendable, Equatable {
    case initialSnapshotScopeMismatch
    case invalidTimeout
    case invalidated(TmuxControlHubInvalidationReason)
    case scopeMismatch(expected: TmuxOperationScope, actual: TmuxOperationScope)
    case snapshotUnavailable
    case destructiveConfirmationRequired
    case confirmationAlreadyConsumed(UUID)
    case operationOutcomeUnknown(TmuxOperationRequest)
}

/// A verified interactive tmux client identity owned by a data attachment. These facts are
/// generation-local and are supplied to the adapter when it classifies `list-clients` output.
/// Holding this identity does not by itself keep a Control Mode process alive.
package struct TmuxControlInteractiveIdentity: Sendable, Equatable, Hashable {
    package let attachmentID: String
    package let clientID: TmuxClientID
    package let requestedSessionID: TmuxSessionID

    package init(
        attachmentID: String,
        clientID: TmuxClientID,
        requestedSessionID: TmuxSessionID
    ) {
        self.attachmentID = attachmentID
        self.clientID = clientID
        self.requestedSessionID = requestedSessionID
    }
}

package enum TmuxControlObservationTarget: Sendable, Equatable, Hashable {
    case catalog
    case session(TmuxSessionID)
}

package struct TmuxControlHubLease: Sendable, Equatable, Hashable {
    fileprivate let id: UUID
}

package struct TmuxControlHubObservation: Sendable {
    package let lease: TmuxControlHubLease
    package let snapshots: AsyncStream<TmuxServerSnapshot>
}

package struct TmuxControlHubStatus: Sendable, Equatable {
    package let identityLeaseCount: Int
    package let observationLeaseCount: Int
    package let pendingOperationCount: Int
    package let operationInFlight: Bool
    package let invalidationReason: TmuxControlHubInvalidationReason?

    package var requiresControlRuntime: Bool {
        invalidationReason == nil && (observationLeaseCount > 0 || pendingOperationCount > 0)
    }

    package var canEvict: Bool {
        identityLeaseCount == 0
            && observationLeaseCount == 0
            && pendingOperationCount == 0
    }
}

/// Complete desired runtime state published in sequence to the adapter. The adapter may open
/// SSH Control Mode clients, one-shot executors, local processes, or future agent transports;
/// none of those choices leak back into the Hub.
package struct TmuxControlHubDemand: Sendable, Equatable {
    package let sequence: UInt64
    package let scope: TmuxOperationScope
    package let observationTargets: Set<TmuxControlObservationTarget>
    package let identities: Set<TmuxControlInteractiveIdentity>
    package let hasPendingOperations: Bool
    package let isInvalidated: Bool

    package var requiresControlRuntime: Bool {
        !isInvalidated && (!observationTargets.isEmpty || hasPendingOperations)
    }
}

package struct TmuxControlHubOperationReceipt: Sendable, Equatable {
    package let request: TmuxOperationRequest
    package let output: [Data]

    package init(request: TmuxOperationRequest, output: [Data]) {
        self.request = request
        self.output = output
    }
}

package enum TmuxControlHubSnapshotReason: Sendable, Equatable {
    case stateEvent(TmuxReconciliationScope)
    case operationCompleted(TmuxOperation)
    case clientRecovery
    case userRequested
}

/// Transport-neutral integration seam. Its implementation owns channel creation and routing;
/// the Hub owns ordering, identity, state, and destructive-operation authority.
package protocol TmuxControlHubAdapter: Sendable {
    func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration
    ) async throws -> TmuxControlHubOperationReceipt

    func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot

    func demandChanged(_ demand: TmuxControlHubDemand) async
}

/// Coordinates one exact tmux server instance. This actor never opens SSH and never renders a
/// command string. Every mutation remains bound to one connection/profile/token/generation.
package actor TmuxControlHub {
    package typealias Clock = @Sendable () -> Date

    private struct ObservationLeaseRecord {
        let target: TmuxControlObservationTarget
        let continuation: AsyncStream<TmuxServerSnapshot>.Continuation
    }

    private let adapter: any TmuxControlHubAdapter
    private let confirmationGuard: TmuxDestructiveConfirmationGuard
    private let clock: Clock
    private var scope: TmuxOperationScope
    private var reducer: TmuxStateReducer
    private var epoch = UUID()
    private var stateRevision = UUID()
    private var latestRefreshID: UUID?
    private var invalidationReason: TmuxControlHubInvalidationReason?

    private var identityLeases: [TmuxControlHubLease: TmuxControlInteractiveIdentity] = [:]
    private var observationLeases: [TmuxControlHubLease: ObservationLeaseRecord] = [:]

    private var pendingOperationCount = 0
    private var operationInFlight = false
    private var operationWaiterOrder: [UUID] = []
    private var operationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    private var consumedConfirmationNonces: [UUID: Date] = [:]
    private var demandSequence: UInt64 = 0
    private var demandNotificationTask: Task<Void, Never>?

    package init(
        scope: TmuxOperationScope,
        initialSnapshot: TmuxServerSnapshot,
        adapter: any TmuxControlHubAdapter,
        confirmationGuard: TmuxDestructiveConfirmationGuard = .init(),
        clock: @escaping Clock = { Date() }
    ) throws {
        guard initialSnapshot.instance.token == scope.instanceToken else {
            throw TmuxControlHubError.initialSnapshotScopeMismatch
        }
        self.scope = scope
        reducer = TmuxStateReducer(snapshot: initialSnapshot, generation: scope.generation)
        self.adapter = adapter
        self.confirmationGuard = confirmationGuard
        self.clock = clock
    }

    package var currentScope: TmuxOperationScope {
        scope
    }

    package var currentSnapshot: TmuxServerSnapshot? {
        invalidationReason == nil ? reducer.snapshot : nil
    }

    package var status: TmuxControlHubStatus {
        TmuxControlHubStatus(
            identityLeaseCount: identityLeases.count,
            observationLeaseCount: observationLeases.count,
            pendingOperationCount: pendingOperationCount,
            operationInFlight: operationInFlight,
            invalidationReason: invalidationReason
        )
    }

    package func acquireIdentityLease(
        _ identity: TmuxControlInteractiveIdentity
    ) throws -> TmuxControlHubLease {
        try requireActive()
        let lease = TmuxControlHubLease(id: UUID())
        identityLeases[lease] = identity
        publishDemand()
        return lease
    }

    package func acquireObservationLease(
        _ target: TmuxControlObservationTarget
    ) throws -> TmuxControlHubObservation {
        try requireActive()
        let lease = TmuxControlHubLease(id: UUID())
        let (stream, continuation) = AsyncStream.makeStream(
            of: TmuxServerSnapshot.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        observationLeases[lease] = ObservationLeaseRecord(
            target: target,
            continuation: continuation
        )
        if let snapshot = reducer.snapshot {
            continuation.yield(snapshot)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.releaseLease(lease) }
        }
        publishDemand()
        return TmuxControlHubObservation(lease: lease, snapshots: stream)
    }

    package func releaseLease(_ lease: TmuxControlHubLease) {
        if identityLeases.removeValue(forKey: lease) != nil {
            publishDemand()
            return
        }
        guard let observation = observationLeases.removeValue(forKey: lease) else {
            return
        }
        observation.continuation.finish()
        publishDemand()
    }

    /// Invalidates this exact-instance Hub when host edits or profile replacement make its
    /// outer runtime identity obsolete. Display-only host edits leave it untouched.
    @discardableResult
    package func invalidateIfRuntimeChanged(
        connectionIdentity: SSHConnectionIdentity,
        profileID: String
    ) -> Bool {
        guard invalidationReason == nil else { return false }
        if connectionIdentity != scope.connectionIdentity {
            invalidate(.connectionIdentityChanged)
            return true
        }
        if profileID != scope.profileID {
            invalidate(.profileChanged)
            return true
        }
        return false
    }

    package func close() {
        invalidate(.closed)
    }

    /// Applies a typed event in generation order. Incomplete topology events are reconciled
    /// through the injected adapter; stale events never cause remote work.
    package func apply(
        _ envelope: TmuxStateEventEnvelope
    ) async throws -> TmuxStateReduction {
        try requireActive()
        let reduction = try reducer.apply(envelope)
        switch reduction {
        case .applied:
            stateRevision = UUID()
            publishSnapshot()
            return .applied
        case let .reconcile(reconciliationScope):
            return try await refresh(reason: .stateEvent(reconciliationScope))
        case .serverInstanceChanged:
            invalidate(.serverInstanceChanged)
            return .serverInstanceChanged
        case .unchanged, .discardedStaleGeneration:
            return reduction
        }
    }

    /// Installs a validated snapshot from an externally established channel generation.
    /// A changed server token invalidates this Hub because the token is part of its registry key.
    package func reconcile(
        with snapshot: TmuxServerSnapshot,
        generation: UInt64
    ) throws -> TmuxStateReduction {
        try requireActive()
        latestRefreshID = nil
        guard snapshot.instance.token == scope.instanceToken else {
            invalidate(.serverInstanceChanged)
            return .serverInstanceChanged
        }

        let previousGeneration = reducer.generation
        let reduction = try reducer.reconcile(with: snapshot, generation: generation)
        switch reduction {
        case .applied:
            stateRevision = UUID()
            if reducer.generation > previousGeneration {
                scope = try TmuxOperationScope(
                    connectionIdentity: scope.connectionIdentity,
                    profileID: scope.profileID,
                    instanceToken: scope.instanceToken,
                    generation: reducer.generation
                )
                epoch = UUID()
                identityLeases.removeAll()
                consumedConfirmationNonces.removeAll()
                publishDemand()
            }
            publishSnapshot()
        case .serverInstanceChanged:
            invalidate(.serverInstanceChanged)
        case .unchanged, .discardedStaleGeneration, .reconcile:
            break
        }
        return reduction
    }

    package func refresh(
        reason: TmuxControlHubSnapshotReason = .userRequested
    ) async throws -> TmuxStateReduction {
        try requireActive()
        let refreshID = UUID()
        latestRefreshID = refreshID
        let requestedScope = scope
        let requestedEpoch = epoch
        let requestedStateRevision = stateRevision
        let identities = Set(identityLeases.values)
        let snapshot = try await adapter.loadSnapshot(
            scope: requestedScope,
            reason: reason,
            identities: identities
        )
        try requireActive()
        guard latestRefreshID == refreshID,
              epoch == requestedEpoch,
              stateRevision == requestedStateRevision,
              scope == requestedScope
        else {
            return .discardedStaleGeneration
        }
        return try reconcile(with: snapshot, generation: requestedScope.generation)
    }

    package func prepareDestructive(
        _ request: TmuxOperationRequest,
        context: TmuxOperationImpactContext = .init()
    ) throws -> TmuxPreparedDestructiveOperation {
        try requireRequestScope(request)
        guard let snapshot = reducer.snapshot else {
            throw TmuxControlHubError.snapshotUnavailable
        }
        return try confirmationGuard.prepare(
            request,
            snapshot: snapshot,
            context: context,
            now: clock()
        )
    }

    package func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration
    ) async throws -> TmuxControlHubOperationReceipt {
        try validateTimeout(timeout)
        try requireRequestScope(request)
        guard !request.operation.isDestructive else {
            throw TmuxControlHubError.destructiveConfirmationRequired
        }

        _ = try await acquireOperationSlot()
        defer { releaseOperationSlot() }
        try Task.checkCancellation()
        try requireRequestScope(request)
        return try await dispatch(request, timeout: timeout)
    }

    package func executeDestructive(
        _ claim: TmuxDestructiveConfirmationClaim,
        for request: TmuxOperationRequest,
        context: TmuxOperationImpactContext = .init(),
        timeout: Duration
    ) async throws -> TmuxControlHubOperationReceipt {
        try validateTimeout(timeout)
        try requireRequestScope(request)
        guard let snapshot = reducer.snapshot else {
            throw TmuxControlHubError.snapshotUnavailable
        }

        let now = clock()
        consumedConfirmationNonces = consumedConfirmationNonces.filter { $0.value > now }
        _ = try confirmationGuard.validate(
            claim,
            for: request,
            snapshot: snapshot,
            context: context,
            now: now
        )
        guard consumedConfirmationNonces[claim.nonce] == nil else {
            throw TmuxControlHubError.confirmationAlreadyConsumed(claim.nonce)
        }
        consumedConfirmationNonces[claim.nonce] = claim.expiresAt

        _ = try await acquireOperationSlot()
        defer { releaseOperationSlot() }
        try Task.checkCancellation()
        try requireRequestScope(request)
        guard let currentSnapshot = reducer.snapshot else {
            throw TmuxControlHubError.snapshotUnavailable
        }
        _ = try confirmationGuard.validate(
            claim,
            for: request,
            snapshot: currentSnapshot,
            context: context,
            now: clock()
        )
        return try await dispatch(request, timeout: timeout)
    }

    private func dispatch(
        _ request: TmuxOperationRequest,
        timeout: Duration
    ) async throws -> TmuxControlHubOperationReceipt {
        let dispatchEpoch = epoch
        let receipt: TmuxControlHubOperationReceipt
        do {
            receipt = try await adapter.execute(request, timeout: timeout)
        } catch {
            guard invalidationReason == nil,
                  epoch == dispatchEpoch,
                  scope == request.scope
            else {
                throw TmuxControlHubError.operationOutcomeUnknown(request)
            }
            throw error
        }

        guard invalidationReason == nil,
              epoch == dispatchEpoch,
              scope == request.scope,
              receipt.request == request
        else {
            throw TmuxControlHubError.operationOutcomeUnknown(request)
        }
        return receipt
    }

    private func acquireOperationSlot() async throws -> UUID {
        try requireActive()
        let ticket = UUID()
        pendingOperationCount += 1
        if !operationInFlight {
            operationInFlight = true
            publishDemand()
            return ticket
        }

        operationWaiterOrder.append(ticket)
        publishDemand()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        operationWaiterOrder.removeAll { $0 == ticket }
                        continuation.resume(throwing: CancellationError())
                    } else {
                        operationWaiters[ticket] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelQueuedOperation(ticket) }
            }
            return ticket
        } catch {
            pendingOperationCount -= 1
            publishDemand()
            throw error
        }
    }

    private func cancelQueuedOperation(_ ticket: UUID) {
        guard let continuation = operationWaiters.removeValue(forKey: ticket) else {
            return
        }
        operationWaiterOrder.removeAll { $0 == ticket }
        continuation.resume(throwing: CancellationError())
    }

    private func releaseOperationSlot() {
        precondition(pendingOperationCount > 0)
        pendingOperationCount -= 1
        while !operationWaiterOrder.isEmpty {
            let next = operationWaiterOrder.removeFirst()
            guard let continuation = operationWaiters.removeValue(forKey: next) else {
                continue
            }
            continuation.resume()
            publishDemand()
            return
        }
        operationInFlight = false
        publishDemand()
    }

    private func invalidate(_ reason: TmuxControlHubInvalidationReason) {
        guard invalidationReason == nil else { return }
        invalidationReason = reason
        epoch = UUID()
        latestRefreshID = nil
        identityLeases.removeAll()

        let observations = Array(observationLeases.values)
        observationLeases.removeAll()
        for observation in observations {
            observation.continuation.finish()
        }

        let waiters = Array(operationWaiters.values)
        operationWaiters.removeAll()
        operationWaiterOrder.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: TmuxControlHubError.invalidated(reason))
        }
        publishDemand()
    }

    private func requireActive() throws {
        if let invalidationReason {
            throw TmuxControlHubError.invalidated(invalidationReason)
        }
    }

    private func requireRequestScope(_ request: TmuxOperationRequest) throws {
        try requireActive()
        guard request.scope == scope else {
            throw TmuxControlHubError.scopeMismatch(
                expected: scope,
                actual: request.scope
            )
        }
    }

    private func validateTimeout(_ timeout: Duration) throws {
        guard timeout > .zero else {
            throw TmuxControlHubError.invalidTimeout
        }
    }

    private func publishSnapshot() {
        guard let snapshot = reducer.snapshot else { return }
        for observation in observationLeases.values {
            observation.continuation.yield(snapshot)
        }
    }

    private func publishDemand() {
        demandSequence &+= 1
        let demand = TmuxControlHubDemand(
            sequence: demandSequence,
            scope: scope,
            observationTargets: Set(observationLeases.values.map(\.target)),
            identities: Set(identityLeases.values),
            hasPendingOperations: pendingOperationCount > 0,
            isInvalidated: invalidationReason != nil
        )
        let predecessor = demandNotificationTask
        let adapter = adapter
        demandNotificationTask = Task {
            await predecessor?.value
            await adapter.demandChanged(demand)
        }
    }
}
