import Foundation
import OSLog

private let tmuxControlRegistryLogger = Logger(
    subsystem: "com.crazyball.Conn",
    category: "TmuxControlRegistry"
)

/// The required Control Mode process is shared by all tmux attachments that point at one exact
/// connection/configuration/server generation. Data attachments remain independent PTYs; this
/// registry owns the shared management-plane runtime and exact per-attachment bindings.
actor TmuxProviderControlRuntimeRegistry {
    private struct Entry {
        var runtime: TmuxControlRuntime?
        var hub: TmuxControlHub?
        var pendingCount: Int
        var openingTask: Task<TmuxControlRuntime?, Never>?
        var creatingHub = false
        /// Changes whenever a caller starts using this runtime. An eviction decision
        /// crosses an actor boundary to inspect the Hub, so `pendingCount` alone is not
        /// sufficient: a new acquisition can start and finish while that await is in
        /// progress. The epoch makes that completed acquisition visible on resume.
        var activityEpoch: UUID
    }

    private struct AttachmentRegistration {
        let identity: TmuxControlInteractiveIdentity
        let attachmentGeneration: UInt64
        let snapshots: AsyncStream<TmuxServerSnapshot>
        let continuation: AsyncStream<TmuxServerSnapshot>.Continuation
        var bindingID: UUID?
        var hubLease: TmuxControlHubLease?
        var observationTask: Task<Void, Never>?
    }

    private var entries: [TmuxOperationScope: Entry] = [:]
    /// Bindings are indexed separately from the shared runtime so Hub setup and teardown can
    /// be transactional. A published attachment is ready only while its binding and runtime
    /// are both valid; this table is not an optional data-only fallback.
    private var attachmentRegistrations: [
        TmuxOperationScope: [UUID: AttachmentRegistration]
    ] = [:]
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireRuntime(
        for scope: TmuxOperationScope,
        opener: @Sendable @escaping () async -> TmuxControlRuntime?
    ) async -> TmuxProviderControlRuntimeLease? {
        if var entry = entries[scope] {
            if let openingTask = entry.openingTask {
                let runtime = await openingTask.value
                guard let runtime, var current = entries[scope] else {
                    return nil
                }
                current.runtime = runtime
                current.pendingCount += 1
                current.activityEpoch = UUID()
                entries[scope] = current
                return TmuxProviderControlRuntimeLease(
                    registry: self,
                    scope: scope,
                    runtime: runtime
                )
            }

            guard let runtime = entry.runtime else { return nil }
            entry.pendingCount += 1
            entry.activityEpoch = UUID()
            entries[scope] = entry
            return TmuxProviderControlRuntimeLease(
                registry: self,
                scope: scope,
                runtime: runtime
            )
        }

        // Install the entry before awaiting the opener. This prevents two tabs arriving at
        // the same time from opening two independent `tmux -CC` processes.
        let openingTask = Task { await opener() }
        entries[scope] = Entry(
            runtime: nil,
            hub: nil,
            pendingCount: 1,
            openingTask: openingTask,
            creatingHub: false,
            activityEpoch: UUID()
        )
        let runtime = await openingTask.value
        guard let runtime, var entry = entries[scope], entry.openingTask != nil else {
            entries.removeValue(forKey: scope)
            signalChange()
            return nil
        }
        entry.runtime = runtime
        entry.openingTask = nil
        entries[scope] = entry
        signalChange()
        return TmuxProviderControlRuntimeLease(
            registry: self,
            scope: scope,
            runtime: runtime
        )
    }

    func releasePreflight(_ lease: TmuxProviderControlRuntimeLease) async {
        guard var entry = entries[lease.scope], entry.runtime === lease.runtime else { return }
        entry.pendingCount = max(0, entry.pendingCount - 1)
        entries[lease.scope] = entry
        await evictIfUnused(scope: lease.scope, runtime: lease.runtime)
    }

    func acquireAttachment(
        _ preflight: TmuxProviderControlRuntimeLease,
        attachmentID: String,
        attachmentGeneration: UInt64,
        requestedSessionID: TmuxSessionID,
        makeHub: @Sendable @escaping (TmuxControlRuntime) async -> TmuxProviderControlSetup?,
        resolveIdentity: @Sendable @escaping (TmuxControlRuntime) async -> TmuxControlInteractiveIdentity?
    ) async -> TmuxProviderControlInteractionLease? {
        while true {
            guard let entry = entries[preflight.scope], entry.runtime === preflight.runtime else {
                return nil
            }

            if let hub = entry.hub {
                guard let identity = await resolveIdentity(preflight.runtime),
                      identity.attachmentID == attachmentID,
                      identity.requestedSessionID == requestedSessionID
                else {
                    await releasePreflight(preflight)
                    return nil
                }
                do {
                    let registration = try await registerAttachment(
                        identity,
                        attachmentGeneration: attachmentGeneration,
                        on: hub,
                        scope: preflight.scope,
                        refreshBeforeValidation: true
                    )
                    guard var current = entries[preflight.scope], current.runtime === preflight.runtime else {
                        await removeAttachmentRegistration(
                            registration.id,
                            scope: preflight.scope
                        )
                        await releasePreflight(preflight)
                        return nil
                    }
                    current.pendingCount = max(0, current.pendingCount - 1)
                    entries[preflight.scope] = current
                    let lease = TmuxProviderControlInteractionLease(
                        registry: self,
                        scope: preflight.scope,
                        runtime: preflight.runtime,
                        registrationID: registration.id,
                        snapshots: registration.snapshots,
                        identity: identity,
                        attachmentGeneration: attachmentGeneration
                    )
                    await evictIfUnused(
                        scope: preflight.scope,
                        runtime: preflight.runtime,
                        hub: hub
                    )
                    return lease
                } catch {
                    tmuxControlRegistryLogger.error(
                        "Registering attachment on existing Hub failed; type=\(String(reflecting: type(of: error)), privacy: .public)"
                    )
                    await releasePreflight(preflight)
                    return nil
                }
            }

            guard !entry.creatingHub else {
                await waitForChange()
                continue
            }

            var creating = entry
            creating.creatingHub = true
            entries[preflight.scope] = creating
            let setup = await makeHub(preflight.runtime)
            guard let setup else {
                guard var current = entries[preflight.scope], current.runtime === preflight.runtime else {
                    return nil
                }
                current.creatingHub = false
                current.pendingCount = max(0, current.pendingCount - 1)
                entries[preflight.scope] = current
                signalChange()
                await evictIfUnused(scope: preflight.scope, runtime: preflight.runtime)
                return nil
            }

            do {
                let registration = try await registerAttachment(
                    setup.identity,
                    attachmentGeneration: attachmentGeneration,
                    on: setup.hub,
                    scope: preflight.scope,
                    refreshBeforeValidation: false
                )
                // Bind the identity used to build the validated initial snapshot before
                // restoring older registrations. If restoration needs one refresh, that
                // refresh then includes both the new and restored identities and cannot
                // accidentally reclassify the new data client as external.
                try await restoreAttachmentRegistrations(
                    on: setup.hub,
                    scope: preflight.scope
                )
                guard var current = entries[preflight.scope], current.runtime === preflight.runtime else {
                    await removeAttachmentRegistration(
                        registration.id,
                        scope: preflight.scope
                    )
                    await releaseHubLeases(from: setup.hub, scope: preflight.scope)
                    return nil
                }
                current.hub = setup.hub
                current.creatingHub = false
                current.pendingCount = max(0, current.pendingCount - 1)
                entries[preflight.scope] = current
                // Do not consume buffered topology notifications until the validated
                // initial snapshot has been bound to this attachment. Starting the event
                // stream earlier lets an ordinary `%sessions-changed` race the required
                // identity registration and can make a healthy startup fail intermittently.
                await setup.hub.startEventStream(preflight.runtime.events)
                signalChange()
                let lease = TmuxProviderControlInteractionLease(
                    registry: self,
                    scope: preflight.scope,
                    runtime: preflight.runtime,
                    registrationID: registration.id,
                    snapshots: registration.snapshots,
                    identity: setup.identity,
                    attachmentGeneration: attachmentGeneration
                )
                await evictIfUnused(
                    scope: preflight.scope,
                    runtime: preflight.runtime,
                    hub: setup.hub
                )
                return lease
            } catch {
                tmuxControlRegistryLogger.error(
                    "Registering attachment on new Hub failed; type=\(String(reflecting: type(of: error)), privacy: .public)"
                )
                await releaseHubLeases(from: setup.hub, scope: preflight.scope)
                guard var current = entries[preflight.scope], current.runtime === preflight.runtime else {
                    return nil
                }
                current.creatingHub = false
                current.pendingCount = max(0, current.pendingCount - 1)
                entries[preflight.scope] = current
                signalChange()
                await evictIfUnused(scope: preflight.scope, runtime: preflight.runtime)
                return nil
            }
        }
    }

    func acquireCatalog(
        _ preflight: TmuxProviderControlRuntimeLease,
        makeHub: @Sendable @escaping (TmuxControlRuntime) async -> TmuxControlHub?
    ) async -> TmuxProviderControlCatalogLease? {
        while true {
            guard let entry = entries[preflight.scope], entry.runtime === preflight.runtime else {
                return nil
            }

            if let hub = entry.hub {
                do {
                    let observation = try await hub.acquireObservationLease(.catalog)
                    guard var current = entries[preflight.scope], current.runtime === preflight.runtime else {
                        await hub.releaseLease(observation.lease)
                        await releasePreflight(preflight)
                        return nil
                    }
                    current.pendingCount = max(0, current.pendingCount - 1)
                    entries[preflight.scope] = current
                    return TmuxProviderControlCatalogLease(
                        registry: self,
                        scope: preflight.scope,
                        runtime: preflight.runtime,
                        hub: hub,
                        observation: observation
                    )
                } catch {
                    await releasePreflight(preflight)
                    return nil
                }
            }

            guard !entry.creatingHub else {
                await waitForChange()
                continue
            }

            var creating = entry
            creating.creatingHub = true
            entries[preflight.scope] = creating
            guard let hub = await makeHub(preflight.runtime) else {
                guard var current = entries[preflight.scope], current.runtime === preflight.runtime else {
                    return nil
                }
                current.creatingHub = false
                current.pendingCount = max(0, current.pendingCount - 1)
                entries[preflight.scope] = current
                signalChange()
                await evictIfUnused(scope: preflight.scope, runtime: preflight.runtime)
                return nil
            }

            do {
                try await restoreAttachmentRegistrations(
                    on: hub,
                    scope: preflight.scope
                )
                let observation = try await hub.acquireObservationLease(.catalog)
                guard var current = entries[preflight.scope], current.runtime === preflight.runtime else {
                    await hub.releaseLease(observation.lease)
                    await releaseHubLeases(from: hub, scope: preflight.scope)
                    return nil
                }
                current.hub = hub
                current.creatingHub = false
                current.pendingCount = max(0, current.pendingCount - 1)
                entries[preflight.scope] = current
                signalChange()
                return TmuxProviderControlCatalogLease(
                    registry: self,
                    scope: preflight.scope,
                    runtime: preflight.runtime,
                    hub: hub,
                    observation: observation
                )
            } catch {
                await releaseHubLeases(from: hub, scope: preflight.scope)
                guard var current = entries[preflight.scope], current.runtime === preflight.runtime else {
                    return nil
                }
                current.creatingHub = false
                current.pendingCount = max(0, current.pendingCount - 1)
                entries[preflight.scope] = current
                signalChange()
                await evictIfUnused(scope: preflight.scope, runtime: preflight.runtime)
                return nil
            }
        }
    }

    func release(_ lease: TmuxProviderControlInteractionLease) async {
        await removeAttachmentRegistration(lease.registrationID, scope: lease.scope)
        if let runtime = entries[lease.scope]?.runtime {
            await evictIfUnused(scope: lease.scope, runtime: runtime)
        }
    }

    func resolveInteraction(
        _ lease: TmuxProviderControlInteractionLease
    ) async throws -> PersistentTerminalInteractionState {
        try await resolveInteractionContext(lease).state
    }

    func resolveInteractionContext(
        _ lease: TmuxProviderControlInteractionLease,
        refreshIfNeeded: Bool = true
    ) async throws -> TmuxResolvedInteractionState {
        guard let registration = attachmentRegistrations[lease.scope]?[lease.registrationID],
              let entry = entries[lease.scope],
              let hub = entry.hub,
              entry.runtime != nil,
              let hubLease = registration.hubLease,
              registration.bindingID != nil
        else {
            throw TmuxInteractionError.closed
        }
        let resolved = try await hub.resolveInteraction(
            lease: hubLease,
            attachmentGeneration: registration.attachmentGeneration,
            refreshIfNeeded: refreshIfNeeded
        )
        guard let current = attachmentRegistrations[lease.scope]?[lease.registrationID],
              current.hubLease == hubLease,
              entries[lease.scope]?.hub === hub
        else {
            throw TmuxInteractionError.closed
        }
        return resolved
    }

    func scrollInteraction(
        _ lease: TmuxProviderControlInteractionLease,
        request: PersistentTerminalModeScrollRequest
    ) async throws {
        guard let registration = attachmentRegistrations[lease.scope]?[lease.registrationID]
        else {
            throw TmuxInteractionError.closed
        }
        guard request.attachmentGeneration == registration.attachmentGeneration else {
            throw PersistentTerminalInteractionError.staleAttachmentGeneration
        }
        guard
              let hub = entries[lease.scope]?.hub,
              let hubLease = registration.hubLease
        else {
            throw TmuxInteractionError.closed
        }
        _ = try await hub.executeModeScroll(
            lease: hubLease,
            target: request.target,
            attachmentGeneration: registration.attachmentGeneration,
            expectedRevision: request.expectedStateRevision,
            direction: request.direction,
            rows: request.rows,
            timeout: .seconds(5)
        )
    }

    func performQuickAction(
        _ lease: TmuxProviderControlInteractionLease,
        request: PersistentTerminalQuickActionRequest
    ) async throws {
        guard let registration = attachmentRegistrations[lease.scope]?[lease.registrationID]
        else {
            throw TmuxInteractionError.closed
        }
        guard request.attachmentGeneration == registration.attachmentGeneration else {
            throw PersistentTerminalInteractionError.staleAttachmentGeneration
        }
        guard let action = TmuxTerminalQuickAction(rawValue: request.actionID) else {
            throw PersistentTerminalInteractionError.unsupportedQuickAction(request.actionID)
        }
        guard (1 ... PersistentTerminalQuickActionRequest.maximumRepeatCount)
            .contains(request.repeatCount)
        else {
            throw PersistentTerminalInteractionError.invalidQuickActionRepeatCount(
                request.repeatCount
            )
        }
        guard let hub = entries[lease.scope]?.hub,
              let hubLease = registration.hubLease
        else {
            throw TmuxInteractionError.closed
        }
        _ = try await hub.executeQuickAction(
            lease: hubLease,
            target: request.target,
            attachmentGeneration: registration.attachmentGeneration,
            expectedRevision: request.expectedStateRevision,
            action: action,
            argument: request.argument,
            repeatCount: request.repeatCount,
            timeout: .seconds(30)
        )
    }

    /// A lease proves ownership of the management route, but its long-lived Control Mode
    /// process may already have terminated. Quick interactions must not enter the Hub's
    /// slower one-shot reconciliation path when the direct command channel is gone.
    func hasReadyControlRuntime(
        _ lease: TmuxProviderControlInteractionLease
    ) async -> Bool {
        guard attachmentRegistrations[lease.scope]?[lease.registrationID] != nil,
              let runtime = entries[lease.scope]?.runtime
        else { return false }
        return await runtime.isReady
    }

    func releaseCatalog(_ lease: TmuxProviderControlCatalogLease) async {
        guard let entry = entries[lease.scope], entry.runtime === lease.runtime else { return }
        await lease.hub.releaseLease(lease.observation.lease)
        await evictIfUnused(scope: lease.scope, runtime: lease.runtime)
    }

    func demandChanged(_ scope: TmuxOperationScope) async {
        guard let entry = entries[scope], let hub = entry.hub else { return }
        guard let runtime = entry.runtime else { return }
        await evictIfUnused(scope: scope, runtime: runtime, hub: hub)
    }

    private func evictIfUnused(
        scope: TmuxOperationScope,
        runtime: TmuxControlRuntime,
        hub: TmuxControlHub? = nil
    ) async {
        guard let entry = entries[scope], entry.runtime === runtime, entry.pendingCount == 0 else {
            return
        }
        let candidateHub = hub ?? entry.hub
        let activityEpoch = entry.activityEpoch
        if let candidateHub, await candidateHub.status.requiresControlRuntime {
            return
        }

        // Reading Hub status suspends this actor. A catalog/attachment acquisition may
        // have reused the runtime and even completed by the time execution resumes, so
        // validate both current demand and acquisition history before closing anything.
        guard let current = entries[scope],
              current.runtime === runtime,
              current.pendingCount == 0,
              current.activityEpoch == activityEpoch,
              current.hub === candidateHub
        else {
            return
        }
        entries.removeValue(forKey: scope)
        clearHubLeases(for: scope)
        signalChange()
        if let candidateHub {
            await candidateHub.close()
        }
        await runtime.close()
    }

    private func registerAttachment(
        _ identity: TmuxControlInteractiveIdentity,
        attachmentGeneration: UInt64,
        on hub: TmuxControlHub,
        scope: TmuxOperationScope,
        refreshBeforeValidation: Bool
    ) async throws -> (id: UUID, snapshots: AsyncStream<TmuxServerSnapshot>) {
        let registrationID = UUID()
        let bindingID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: TmuxServerSnapshot.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        let observation = try await hub.acquireInteractionLease(
            identity: identity,
            target: .session(identity.requestedSessionID)
        )
        attachmentRegistrations[scope, default: [:]][registrationID] = AttachmentRegistration(
            identity: identity,
            attachmentGeneration: attachmentGeneration,
            snapshots: stream,
            continuation: continuation,
            bindingID: bindingID,
            hubLease: observation.lease,
            observationTask: nil
        )
        do {
            if refreshBeforeValidation {
                _ = try await hub.refresh(reason: .userRequested)
            }
            _ = try await hub.resolveInteraction(
                lease: observation.lease,
                attachmentGeneration: attachmentGeneration,
                refreshIfNeeded: false
            )
            guard var registration = attachmentRegistrations[scope]?[registrationID],
                  registration.bindingID == bindingID,
                  let currentEntry = entries[scope],
                  currentEntry.hub == nil || currentEntry.hub === hub
            else {
                await hub.releaseLease(observation.lease)
                throw TmuxInteractionError.closed
            }
            registration.observationTask = forward(
                observation.snapshots,
                registrationID: registrationID,
                scope: scope,
                bindingID: bindingID
            )
            attachmentRegistrations[scope]?[registrationID] = registration
            return (registrationID, stream)
        } catch {
            await hub.releaseLease(observation.lease)
            if attachmentRegistrations[scope]?[registrationID]?.bindingID == bindingID {
                attachmentRegistrations[scope]?[registrationID]?.observationTask?.cancel()
                attachmentRegistrations[scope]?[registrationID]?.continuation.finish()
                attachmentRegistrations[scope]?[registrationID] = nil
            }
            if attachmentRegistrations[scope]?.isEmpty == true {
                attachmentRegistrations[scope] = nil
            }
            throw error
        }
    }

    private func restoreAttachmentRegistrations(
        on hub: TmuxControlHub,
        scope: TmuxOperationScope
    ) async throws {
        let registrationIDs = attachmentRegistrations[scope]?.keys.sorted {
            $0.uuidString < $1.uuidString
        } ?? []
        var acquired: [(registrationID: UUID, bindingID: UUID, observation: TmuxControlHubObservation)] = []
        do {
            for registrationID in registrationIDs {
                guard let registration = attachmentRegistrations[scope]?[registrationID],
                      registration.hubLease == nil
                else { continue }
                let bindingID = UUID()
                let observation = try await hub.acquireInteractionLease(
                    identity: registration.identity,
                    target: .session(registration.identity.requestedSessionID)
                )
                guard var current = attachmentRegistrations[scope]?[registrationID],
                      current.hubLease == nil
                else {
                    await hub.releaseLease(observation.lease)
                    continue
                }
                current.bindingID = bindingID
                current.hubLease = observation.lease
                attachmentRegistrations[scope]?[registrationID] = current
                acquired.append((registrationID, bindingID, observation))
            }
            guard !acquired.isEmpty else { return }
            _ = try await hub.refresh(reason: .userRequested)
            for acquiredBinding in acquired {
                guard var current = attachmentRegistrations[scope]?[acquiredBinding.registrationID],
                      current.bindingID == acquiredBinding.bindingID,
                      current.hubLease == acquiredBinding.observation.lease
                else {
                    await hub.releaseLease(acquiredBinding.observation.lease)
                    continue
                }
                current.observationTask = forward(
                    acquiredBinding.observation.snapshots,
                    registrationID: acquiredBinding.registrationID,
                    scope: scope,
                    bindingID: acquiredBinding.bindingID
                )
                attachmentRegistrations[scope]?[acquiredBinding.registrationID] = current
            }
        } catch {
            for acquiredBinding in acquired {
                if attachmentRegistrations[scope]?[acquiredBinding.registrationID]?.bindingID
                    == acquiredBinding.bindingID
                {
                    attachmentRegistrations[scope]?[acquiredBinding.registrationID]?
                        .observationTask?.cancel()
                    attachmentRegistrations[scope]?[acquiredBinding.registrationID]?
                        .observationTask = nil
                    attachmentRegistrations[scope]?[acquiredBinding.registrationID]?.bindingID = nil
                    attachmentRegistrations[scope]?[acquiredBinding.registrationID]?.hubLease = nil
                }
                await hub.releaseLease(acquiredBinding.observation.lease)
            }
            throw error
        }
    }

    private func removeAttachmentRegistration(
        _ registrationID: UUID,
        scope: TmuxOperationScope
    ) async {
        guard var registrations = attachmentRegistrations[scope],
              let registration = registrations.removeValue(forKey: registrationID)
        else { return }
        if registrations.isEmpty {
            attachmentRegistrations[scope] = nil
        } else {
            attachmentRegistrations[scope] = registrations
        }
        registration.observationTask?.cancel()
        registration.continuation.finish()
        if let lease = registration.hubLease,
           let hub = entries[scope]?.hub
        {
            await hub.releaseLease(lease)
        }
    }

    private func clearHubLeases(for scope: TmuxOperationScope) {
        guard var registrations = attachmentRegistrations[scope] else { return }
        for registrationID in registrations.keys {
            registrations[registrationID]?.hubLease = nil
            registrations[registrationID]?.bindingID = nil
            registrations[registrationID]?.observationTask?.cancel()
            registrations[registrationID]?.observationTask = nil
        }
        attachmentRegistrations[scope] = registrations
    }

    private func releaseHubLeases(
        from hub: TmuxControlHub,
        scope: TmuxOperationScope
    ) async {
        guard var registrations = attachmentRegistrations[scope] else { return }
        for registrationID in registrations.keys {
            registrations[registrationID]?.observationTask?.cancel()
            registrations[registrationID]?.observationTask = nil
            registrations[registrationID]?.bindingID = nil
            if let lease = registrations[registrationID]?.hubLease {
                registrations[registrationID]?.hubLease = nil
                attachmentRegistrations[scope] = registrations
                await hub.releaseLease(lease)
            }
        }
        attachmentRegistrations[scope] = registrations
    }

    private func forward(
        _ source: AsyncStream<TmuxServerSnapshot>,
        registrationID: UUID,
        scope: TmuxOperationScope,
        bindingID: UUID
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await snapshot in source {
                guard !Task.isCancelled else { return }
                await self?.forward(
                    snapshot,
                    registrationID: registrationID,
                    scope: scope,
                    bindingID: bindingID
                )
            }
        }
    }

    private func forward(
        _ snapshot: TmuxServerSnapshot,
        registrationID: UUID,
        scope: TmuxOperationScope,
        bindingID: UUID
    ) {
        guard let registration = attachmentRegistrations[scope]?[registrationID],
              registration.bindingID == bindingID
        else { return }
        registration.continuation.yield(snapshot)
    }

    private func waitForChange() async {
        await withCheckedContinuation { continuation in
            changeWaiters.append(continuation)
        }
    }

    private func signalChange() {
        let waiters = changeWaiters
        changeWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

struct TmuxProviderControlRuntimeLease: Sendable {
    let registry: TmuxProviderControlRuntimeRegistry
    let scope: TmuxOperationScope
    let runtime: TmuxControlRuntime
}

struct TmuxProviderControlSetup: Sendable {
    let hub: TmuxControlHub
    let identity: TmuxControlInteractiveIdentity
}

package struct TmuxProviderControlInteractionLease: Sendable {
    let registry: TmuxProviderControlRuntimeRegistry
    let scope: TmuxOperationScope
    let runtime: TmuxControlRuntime
    let registrationID: UUID
    let snapshots: AsyncStream<TmuxServerSnapshot>
    let identity: TmuxControlInteractiveIdentity
    let attachmentGeneration: UInt64
}

struct TmuxProviderControlCatalogLease: Sendable {
    let registry: TmuxProviderControlRuntimeRegistry
    let scope: TmuxOperationScope
    let runtime: TmuxControlRuntime
    let hub: TmuxControlHub
    let observation: TmuxControlHubObservation
}

struct TmuxControlRuntimeLifecycleBridge: TmuxControlRuntimeLifecycleDriving {
    let runtime: TmuxControlRuntime
    let registry: TmuxProviderControlRuntimeRegistry
    let scope: TmuxOperationScope

    func demandChanged(_ demand: TmuxControlHubDemand) async {
        await runtime.demandChanged(demand)
        await registry.demandChanged(scope)
    }
}
