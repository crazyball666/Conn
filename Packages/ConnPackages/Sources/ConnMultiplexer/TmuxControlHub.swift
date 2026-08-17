import ConnSSH
import Foundation

package enum TmuxControlHubInvalidationReason: Sendable, Equatable {
    case connectionIdentityChanged
    case configurationChanged
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
    package let reconciliationSnapshot: TmuxServerSnapshot?

    package init(
        request: TmuxOperationRequest,
        output: [Data],
        reconciliationSnapshot: TmuxServerSnapshot? = nil
    ) {
        self.request = request
        self.output = output
        self.reconciliationSnapshot = reconciliationSnapshot
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
        timeout: Duration,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxControlHubOperationReceipt

    func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot

    func demandChanged(_ demand: TmuxControlHubDemand) async
}

/// Coordinates one exact tmux server instance. This actor never opens SSH and never renders a
/// command string. Every mutation remains bound to one connection/configuration/token/generation.
package actor TmuxControlHub {
    package typealias Clock = @Sendable () -> Date

    private struct ObservationLeaseRecord {
        let target: TmuxControlObservationTarget
        let continuation: AsyncStream<TmuxServerSnapshot>.Continuation
    }

    private struct InteractionLeaseRecord {
        let identity: TmuxControlInteractiveIdentity
        let target: TmuxControlObservationTarget
        let continuation: AsyncStream<TmuxServerSnapshot>.Continuation
    }

    private let adapter: any TmuxControlHubAdapter
    private let confirmationGuard: TmuxDestructiveConfirmationGuard
    private let clock: Clock
    private let operationImpactContext: TmuxOperationImpactContext
    private var scope: TmuxOperationScope
    private var reducer: TmuxStateReducer
    private var epoch = UUID()
    private var stateRevision = UUID()
    private var latestRefreshID: UUID?
    private var invalidationReason: TmuxControlHubInvalidationReason?

    private var identityLeases: [TmuxControlHubLease: TmuxControlInteractiveIdentity] = [:]
    private var observationLeases: [TmuxControlHubLease: ObservationLeaseRecord] = [:]
    private var interactionLeases: [TmuxControlHubLease: InteractionLeaseRecord] = [:]

    private var pendingOperationCount = 0
    private var operationInFlight = false
    private var operationWaiterOrder: [UUID] = []
    private var operationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    private var consumedConfirmationNonces: [UUID: Date] = [:]
    private var demandSequence: UInt64 = 0
    private var demandNotificationTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    package init(
        scope: TmuxOperationScope,
        initialSnapshot: TmuxServerSnapshot,
        adapter: any TmuxControlHubAdapter,
        confirmationGuard: TmuxDestructiveConfirmationGuard = .init(),
        operationImpactContext: TmuxOperationImpactContext = .init(),
        clock: @escaping Clock = { Date() }
    ) throws {
        guard initialSnapshot.instance.token == scope.instanceToken else {
            throw TmuxControlHubError.initialSnapshotScopeMismatch
        }
        self.scope = scope
        reducer = TmuxStateReducer(snapshot: initialSnapshot, generation: scope.generation)
        self.adapter = adapter
        self.confirmationGuard = confirmationGuard
        self.operationImpactContext = operationImpactContext
        self.clock = clock
        eventTask = nil
    }

    package var currentScope: TmuxOperationScope {
        scope
    }

    package var currentSnapshot: TmuxServerSnapshot? {
        invalidationReason == nil ? reducer.snapshot : nil
    }

    package var status: TmuxControlHubStatus {
        TmuxControlHubStatus(
            identityLeaseCount: identityLeases.count + interactionLeases.count,
            observationLeaseCount: observationLeases.count + interactionLeases.count,
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

    package func acquireInteractionLease(
        identity: TmuxControlInteractiveIdentity,
        target: TmuxControlObservationTarget
    ) throws -> TmuxControlHubObservation {
        try requireActive()
        let lease = TmuxControlHubLease(id: UUID())
        let (stream, continuation) = AsyncStream.makeStream(
            of: TmuxServerSnapshot.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        interactionLeases[lease] = InteractionLeaseRecord(
            identity: identity,
            target: target,
            continuation: continuation
        )
        // The Hub is created from an already validated snapshot. Interaction consumers
        // need that state immediately; requiring a second remote refresh just to publish
        // the first value adds latency and creates a startup race with topology events.
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
        if let interaction = interactionLeases.removeValue(forKey: lease) {
            interaction.continuation.finish()
            publishDemand()
            return
        }
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

    /// Invalidates this exact-instance Hub when host edits or configuration replacement make its
    /// outer runtime identity obsolete. Display-only host edits leave it untouched.
    @discardableResult
    package func invalidateIfRuntimeChanged(
        connectionIdentity: SSHConnectionIdentity,
        configurationKey: String
    ) -> Bool {
        guard invalidationReason == nil else { return false }
        if connectionIdentity != scope.connectionIdentity {
            invalidate(.connectionIdentityChanged)
            return true
        }
        if configurationKey != scope.configurationKey {
            invalidate(.configurationChanged)
            return true
        }
        return false
    }

    package func close() {
        invalidate(.closed)
    }

    package func startEventStream(
        _ eventStream: AsyncStream<TmuxControlClientEvent>
    ) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in eventStream {
                guard let self else { return }
                await self.consume(event)
            }
        }
    }

    private func consume(_ event: TmuxControlClientEvent) async {
        switch event {
        case let .notification(generation, notification):
            let observedAt = clock()
            guard generation == scope.generation,
                  let stateEvent = Self.stateEvent(
                      for: notification,
                      observedAt: observedAt
                  )
            else { return }
            let envelope = TmuxStateEventEnvelope(
                generation: generation,
                serverToken: scope.instanceToken,
                observedAt: observedAt,
                event: stateEvent
            )
            _ = try? await apply(envelope)

        case let .reconciliationRequired(generation, _):
            guard generation == scope.generation else { return }
            _ = try? await refresh(reason: .clientRecovery)

        case .closed:
            invalidate(.closed)

        case .protocolReady, .stderrDiagnostic, .diagnosticsTruncated,
             .lateCommandTerminated:
            break
        }
    }

    private static func stateEvent(
        for notification: TmuxNotification,
        observedAt: Date
    ) -> TmuxStateEvent? {
        switch notification {
        case let .known(notification, payload):
            switch notification {
            case .pause, .continue:
                return nil
            case .subscriptionChanged:
                return subscriptionStateEvent(payload: payload, observedAt: observedAt)
            case .sessionWindowChanged:
                return sessionWindowStateEvent(payload: payload)
            default:
                // Most Control Mode topology notifications do not carry enough data to
                // safely mutate the normalized graph. Reconcile the server snapshot instead
                // of guessing IDs or names from an undocumented payload shape.
                return .sessionsChanged
            }
        case let .unknown(name, _):
            return .unknownNotification(name: name)
        case let .paneOutput(paneID, data), let .extendedPaneOutput(paneID, _, data):
            return .paneOutput(paneID, data)
        case .exit:
            return nil
        }
    }

    /// `%session-window-changed $session @window` is complete enough to update the
    /// normalized graph directly. Window navigation must not launch a full snapshot query
    /// on the same single-command Control Mode channel after every swipe.
    private static func sessionWindowStateEvent(payload: Data) -> TmuxStateEvent {
        guard let text = String(data: payload, encoding: .utf8) else {
            return .protocolViolation
        }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2,
              let sessionID = TmuxSessionID(rawValue: String(fields[0])),
              let windowID = TmuxWindowID(rawValue: String(fields[1]))
        else { return .protocolViolation }
        return .sessionCurrentWindowChanged(sessionID, windowID: windowID)
    }

    /// `%subscription-changed name session window index pane ... : value` is the one
    /// notification whose payload is self-contained enough to update pane metadata without
    /// a snapshot reload. Fields after pane and before `:` are reserved by tmux and ignored.
    private static func subscriptionStateEvent(
        payload: Data,
        observedAt: Date
    ) -> TmuxStateEvent {
        let delimiter = Data(" : ".utf8)
        guard let delimiterRange = payload.range(of: delimiter),
              let header = String(
                  data: Data(payload[..<delimiterRange.lowerBound]),
                  encoding: .utf8
              )
        else { return .protocolViolation }

        let fields = header.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 5 else { return .protocolViolation }
        let name = String(fields[0])
        if name == "__conn_session_attached__" {
            return .sessionsChanged
        }
        guard let paneID = TmuxPaneID(rawValue: String(fields[4])),
              let value = decodeEscapedSubscriptionValue(
                  Data(payload[delimiterRange.upperBound...])
              )
        else { return .protocolViolation }

        let field: TmuxPaneMetadataField
        switch name {
        case "__conn_pane_title__": field = .title
        case "__conn_pane_current_command__": field = .currentCommand
        case "__conn_pane_current_path__": field = .currentPath
        default:
            return .unknownNotification(name: "subscription-changed:\(name)")
        }
        return .paneMetadataChanged(
            paneID,
            field: field,
            value: TmuxObservedValue(
                value: value,
                freshness: .liveSubscription(observedAt: observedAt)
            )
        )
    }

    /// Control Mode escapes non-printable bytes and backslashes as `\\ooo`. Decode only
    /// that documented wire form and require valid UTF-8 before exposing text to the UI.
    private static func decodeEscapedSubscriptionValue(_ encoded: Data) -> String? {
        let bytes = Array(encoded)
        var decoded = Data()
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                guard index + 3 < bytes.count else { return nil }
                let digits = bytes[(index + 1) ... (index + 3)]
                guard digits.allSatisfy({
                    (UInt8(ascii: "0") ... UInt8(ascii: "7")).contains($0)
                }) else { return nil }
                let value = Int(digits[digits.startIndex] - UInt8(ascii: "0")) * 64
                    + Int(digits[digits.index(after: digits.startIndex)] - UInt8(ascii: "0")) * 8
                    + Int(digits[digits.index(digits.startIndex, offsetBy: 2)] - UInt8(ascii: "0"))
                guard value <= UInt8.max else { return nil }
                decoded.append(UInt8(value))
                index += 4
            } else {
                guard byte >= UInt8(ascii: " ") else { return nil }
                decoded.append(byte)
                index += 1
            }
        }
        return String(data: decoded, encoding: .utf8)
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
                    configurationKey: scope.configurationKey,
                    instanceToken: scope.instanceToken,
                    generation: reducer.generation
                )
                epoch = UUID()
                identityLeases.removeAll()
                finishInteractionLeases()
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
        let identities = activeIdentities
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
        context: TmuxOperationImpactContext? = nil
    ) async throws -> TmuxPreparedDestructiveOperation {
        try requireRequestScope(request)
        _ = try await refresh(reason: .userRequested)
        try requireRequestScope(request)
        guard let snapshot = reducer.snapshot else {
            throw TmuxControlHubError.snapshotUnavailable
        }
        return try confirmationGuard.prepare(
            request,
            snapshot: snapshot,
            context: effectiveImpactContext(
                for: request.operation,
                snapshot: snapshot,
                explicit: context
            ),
            now: clock()
        )
    }

    package func previewImpact(
        _ request: TmuxOperationRequest,
        context: TmuxOperationImpactContext? = nil
    ) async throws -> TmuxOperationImpact {
        try requireRequestScope(request)
        _ = try await refresh(reason: .userRequested)
        try requireRequestScope(request)
        guard let snapshot = reducer.snapshot else {
            throw TmuxControlHubError.snapshotUnavailable
        }
        return try TmuxOperationImpactAnalyzer().analyze(
            request.operation,
            in: snapshot,
            context: effectiveImpactContext(
                for: request.operation,
                snapshot: snapshot,
                explicit: context
            )
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
        return try await dispatch(
            request,
            timeout: timeout,
            identities: activeIdentities
        )
    }

    package func executeModeScroll(
        lease: TmuxControlHubLease,
        target: PersistentTerminalInteractionTarget,
        attachmentGeneration: UInt64,
        expectedRevision: UInt64,
        direction: PersistentTerminalScrollDirection,
        rows: Int,
        timeout: Duration
    ) async throws -> TmuxControlHubOperationReceipt {
        try validateTimeout(timeout)
        guard (1 ... PersistentTerminalModeScrollRequest.maximumRows).contains(rows) else {
            throw PersistentTerminalInteractionError.invalidScrollRows(rows)
        }

        _ = try await acquireOperationSlot()
        defer { releaseOperationSlot() }
        try Task.checkCancellation()
        try requireActive()
        guard let interactionLease = interactionLeases[lease],
              let snapshot = reducer.snapshot
        else {
            throw TmuxInteractionError.clientUnavailable
        }
        guard snapshot.revision == expectedRevision else {
            throw TmuxInteractionError.staleState(
                expectedRevision: expectedRevision,
                actualRevision: snapshot.revision
            )
        }
        let resolved = try TmuxInteractionStateProjector().resolve(
            snapshot: snapshot,
            identity: interactionLease.identity,
            expectedTarget: target,
            attachmentGeneration: attachmentGeneration
        )
        guard resolved.state.modeCapability == .scrollable else {
            throw TmuxInteractionError.unsupportedMode
        }
        let operation = TmuxOperation.scrollPaneMode(
            resolved.paneID,
            direction: direction == .up ? .up : .down,
            rows: try TmuxScrollRowCount(rows)
        )
        return try await dispatch(
            .init(scope: scope, operation: operation),
            timeout: timeout,
            identities: activeIdentities
        )
    }

    /// Executes one provider-owned quick action against the exact Pane state from which its
    /// button was rendered. Target resolution and operation construction happen inside this
    /// actor so a topology update cannot retarget the action between validation and dispatch.
    package func executeQuickAction(
        lease: TmuxControlHubLease,
        target: PersistentTerminalInteractionTarget,
        attachmentGeneration: UInt64,
        expectedRevision: UInt64,
        action: TmuxTerminalQuickAction,
        argument: String?,
        repeatCount: Int = 1,
        timeout: Duration
    ) async throws -> TmuxControlHubOperationReceipt {
        try validateTimeout(timeout)

        _ = try await acquireOperationSlot()
        defer { releaseOperationSlot() }
        try Task.checkCancellation()
        try requireActive()
        guard let interactionLease = interactionLeases[lease],
              let snapshot = reducer.snapshot
        else {
            throw TmuxInteractionError.clientUnavailable
        }
        let isRelativeWindowNavigation = action == .previousWindow || action == .nextWindow
        if !isRelativeWindowNavigation {
            guard snapshot.revision == expectedRevision else {
                throw TmuxInteractionError.staleState(
                    expectedRevision: expectedRevision,
                    actualRevision: snapshot.revision
                )
            }
        }
        let resolved = try TmuxInteractionStateProjector().resolve(
            snapshot: snapshot,
            identity: interactionLease.identity,
            expectedTarget: isRelativeWindowNavigation ? nil : target,
            attachmentGeneration: attachmentGeneration
        )
        let client = try TmuxClientTarget(interactionLease.identity.clientID.targetName)
        let operation = try action.operation(
            for: resolved,
            client: client,
            argument: argument,
            repeatCount: repeatCount
        )
        let receipt = try await dispatch(
            .init(scope: scope, operation: operation),
            timeout: timeout,
            identities: activeIdentities
        )
        switch action {
        case .newWindow:
            guard let windowID = createdWindowID(from: receipt.output) else {
                throw TmuxInteractionError.createdWindowIdentityUnavailable
            }
            return try await dispatch(
                .init(scope: scope, operation: .selectWindow(windowID, for: client)),
                timeout: timeout,
                identities: activeIdentities
            )
        case .splitHorizontal, .splitVertical:
            guard let paneID = createdPaneID(from: receipt.output) else {
                throw TmuxInteractionError.createdPaneIdentityUnavailable
            }
            return try await dispatch(
                .init(scope: scope, operation: .selectPane(paneID, for: client)),
                timeout: timeout,
                identities: activeIdentities
            )
        case .renameSession, .previousWindow, .nextWindow, .renameWindow,
             .previousPane, .nextPane, .toggleZoom, .swapPanePrevious, .swapPaneNext,
             .resizeLeft, .resizeRight, .resizeUp, .resizeDown,
             .toggleSynchronizePanes, .copyMode, .cycleLayout, .tiledLayout,
             .evenHorizontalLayout, .evenVerticalLayout, .mainHorizontalLayout,
             .mainVerticalLayout:
            return receipt
        }
    }

    private func createdWindowID(from output: [Data]) -> TmuxWindowID? {
        outputTokens(output).compactMap(TmuxWindowID.init(rawValue:)).first
    }

    private func createdPaneID(from output: [Data]) -> TmuxPaneID? {
        outputTokens(output).compactMap(TmuxPaneID.init(rawValue:)).first
    }

    private func outputTokens(_ output: [Data]) -> [String] {
        output.flatMap { chunk in
            String(decoding: chunk, as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
        }
    }

    package func resolveInteraction(
        lease: TmuxControlHubLease,
        attachmentGeneration: UInt64,
        expectedTarget: PersistentTerminalInteractionTarget? = nil,
        refreshIfNeeded: Bool
    ) async throws -> TmuxResolvedInteractionState {
        if refreshIfNeeded {
            _ = try await refresh(reason: .userRequested)
        }
        try requireActive()
        guard let interactionLease = interactionLeases[lease],
              let snapshot = reducer.snapshot
        else {
            throw TmuxInteractionError.closed
        }
        return try TmuxInteractionStateProjector().resolve(
            snapshot: snapshot,
            identity: interactionLease.identity,
            expectedTarget: expectedTarget,
            attachmentGeneration: attachmentGeneration
        )
    }

    package func executeDestructive(
        _ claim: TmuxDestructiveConfirmationClaim,
        for request: TmuxOperationRequest,
        context: TmuxOperationImpactContext? = nil,
        timeout: Duration
    ) async throws -> TmuxControlHubOperationReceipt {
        try validateTimeout(timeout)
        try requireRequestScope(request)
        _ = try await refresh(reason: .userRequested)
        try requireRequestScope(request)
        guard let snapshot = reducer.snapshot else {
            throw TmuxControlHubError.snapshotUnavailable
        }

        let now = clock()
        consumedConfirmationNonces = consumedConfirmationNonces.filter { $0.value > now }
        let effectiveContext = effectiveImpactContext(
            for: request.operation,
            snapshot: snapshot,
            explicit: context
        )
        _ = try confirmationGuard.validate(
            claim,
            for: request,
            snapshot: snapshot,
            context: effectiveContext,
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
            context: effectiveContext,
            now: clock()
        )
        return try await dispatch(
            request,
            timeout: timeout,
            identities: activeIdentities
        )
    }

    /// Catalog operations do not have one permanent initiating tab: the same Hub may be
    /// created by a catalog or by any of several attachments. Resolve client-local context
    /// from the operation's verified target in the current snapshot instead of retaining
    /// whichever attachment happened to create the shared Hub first.
    private func effectiveImpactContext(
        for operation: TmuxOperation,
        snapshot: TmuxServerSnapshot,
        explicit: TmuxOperationImpactContext?
    ) -> TmuxOperationImpactContext {
        if let explicit { return explicit }

        let target: TmuxClientTarget?
        switch operation {
        case let .detachClient(client),
             let .selectWindow(_, client),
             let .selectRelativeWindow(_, _, _, client),
             let .selectPane(_, client):
            target = client
        default:
            target = nil
        }
        guard let target,
              let client = snapshot.clients.values.first(where: {
                  $0.id.targetName == target.value
              }),
              case let .connInteractive(attachmentID) = client.role
        else {
            return TmuxOperationImpactContext(
                paneFocusIsolation: operationImpactContext.paneFocusIsolation
            )
        }
        return TmuxOperationImpactContext(
            initiatingAttachmentID: attachmentID,
            paneFocusIsolation: client.flags?.contains(.activePane) == true
                ? .clientLocal
                : .sharedWindow
        )
    }

    private func dispatch(
        _ request: TmuxOperationRequest,
        timeout: Duration,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxControlHubOperationReceipt {
        let dispatchEpoch = epoch
        let receipt: TmuxControlHubOperationReceipt
        do {
            receipt = try await adapter.execute(
                request,
                timeout: timeout,
                identities: identities
            )
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

        if let reconciliationSnapshot = receipt.reconciliationSnapshot {
            let reduction = try reconcile(
                with: reconciliationSnapshot,
                generation: request.scope.generation
            )
            guard reduction == .applied || reduction == .unchanged else {
                throw TmuxControlHubError.operationOutcomeUnknown(request)
            }
            guard invalidationReason == nil,
                  epoch == dispatchEpoch,
                  scope == request.scope
            else {
                throw TmuxControlHubError.operationOutcomeUnknown(request)
            }
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
        eventTask?.cancel()
        eventTask = nil
        epoch = UUID()
        latestRefreshID = nil
        identityLeases.removeAll()
        finishInteractionLeases()

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
        for interaction in interactionLeases.values {
            interaction.continuation.yield(snapshot)
        }
    }

    private var activeIdentities: Set<TmuxControlInteractiveIdentity> {
        Set(identityLeases.values).union(interactionLeases.values.map(\.identity))
    }

    private func finishInteractionLeases() {
        let interactions = Array(interactionLeases.values)
        interactionLeases.removeAll()
        for interaction in interactions {
            interaction.continuation.finish()
        }
    }

    private func publishDemand() {
        demandSequence &+= 1
        let demand = TmuxControlHubDemand(
            sequence: demandSequence,
            scope: scope,
            observationTargets: Set(observationLeases.values.map(\.target))
                .union(interactionLeases.values.map(\.target)),
            identities: activeIdentities,
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
