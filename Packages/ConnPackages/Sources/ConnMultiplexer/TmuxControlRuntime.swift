import ConnSSH
import Foundation

package struct TmuxControlProcessIdentity: Sendable, Equatable {
    package let tty: String
    package let processID: Int32

    package init(tty: String, processID: Int32) {
        self.tty = tty
        self.processID = processID
    }
}

package enum TmuxDataClientFocusPolicy {
    package static func shouldEnableActivePane(
        for identity: TmuxControlInteractiveIdentity,
        clients: [TmuxClientID: TmuxClientSnapshot],
        supportsActivePane: Bool
    ) -> Bool {
        guard supportsActivePane,
              let dataClient = clients[identity.clientID],
              case let .connInteractive(attachmentID) = dataClient.role,
              attachmentID == identity.attachmentID,
              dataClient.kind == .interactiveTerminal
        else { return false }
        return dataClient.flags?.contains(.activePane) != true
    }
}

/// `AsyncStream` iterators compete for elements, so exposing one shared stream would let
/// only one of several attachments observe a shared Control Mode failure. This small
/// broadcaster gives every attachment its own buffered subscription and replays the terminal
/// reason to a subscriber that arrives concurrently with shutdown.
private final class TmuxControlTerminationBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [
        UUID: AsyncStream<TmuxControlClientTermination>.Continuation
    ] = [:]
    private var terminalReason: TmuxControlClientTermination?

    func stream() -> AsyncStream<TmuxControlClientTermination> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: TmuxControlClientTermination.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        let observedReason = lock.withLock { () -> TmuxControlClientTermination? in
            if let terminalReason = self.terminalReason { return terminalReason }
            continuations[id] = continuation
            return nil
        }
        if let observedReason {
            continuation.yield(observedReason)
            continuation.finish()
        }
        return stream
    }

    func finish(_ reason: TmuxControlClientTermination) {
        let active = lock.withLock { () -> [AsyncStream<TmuxControlClientTermination>.Continuation] in
            guard terminalReason == nil else { return [] }
            terminalReason = reason
            let active = Array(continuations.values)
            continuations.removeAll()
            return active
        }
        for continuation in active {
            continuation.yield(reason)
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.withLock { continuations[id] = nil }
    }
}

/// Runtime owner for one direct `tmux -CC` process generation.
///
/// The process channel is supplied by the provider so this type stays independent
/// of Citadel, MockSSH and future SSH engines. It owns only Control Mode lifecycle;
/// the data attachment and shared SSH session remain separate resources.
package actor TmuxControlRuntime {
    private let client: TmuxControlClient
    private let eventContinuation: AsyncStream<TmuxControlClientEvent>.Continuation
    private nonisolated let terminationBroadcaster: TmuxControlTerminationBroadcaster

    package let scope: TmuxOperationScope
    package let dialect: TmuxProtocolDialect
    package let processIdentity: TmuxControlProcessIdentity
    package let events: AsyncStream<TmuxControlClientEvent>
    private let snapshotLoader: TmuxSnapshotLoader
    private var controlClientID: TmuxClientID?
    private var negotiatedCapabilities = TmuxNegotiatedCapabilities(
        supportedClientFlags: [],
        supportsFormatSubscriptions: false
    )
    private var clientConfiguration = TmuxControlClientConfiguration(
        enabledClientFlags: [],
        activeSubscriptionNames: []
    )

    package init(
        channel: any RemoteProcessChannel,
        scope: TmuxOperationScope,
        dialect: TmuxProtocolDialect,
        processIdentity: TmuxControlProcessIdentity,
        limits: TmuxControlClientLimits = .default,
        eventHandler: @escaping TmuxControlClient.EventHandler = { _ in }
    ) throws {
        self.scope = scope
        self.dialect = dialect
        self.processIdentity = processIdentity
        let (events, eventContinuation) = AsyncStream<TmuxControlClientEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let terminationBroadcaster = TmuxControlTerminationBroadcaster()
        self.events = events
        self.eventContinuation = eventContinuation
        self.terminationBroadcaster = terminationBroadcaster
        let client = try TmuxControlClient(
            channel: channel,
            generation: scope.generation,
            dialect: dialect,
            limits: limits,
            eventHandler: { event in
                eventContinuation.yield(event)
                await eventHandler(event)
                if case let .closed(_, reason) = event {
                    terminationBroadcaster.finish(reason)
                    eventContinuation.finish()
                }
            }
        )
        self.client = client
        controlClientID = nil
        snapshotLoader = TmuxSnapshotLoader(
            executor: TmuxControlClientReadOnlyExecutor(client: client, scope: scope),
            nonceFactory: {
                try TmuxInvocationNonce(
                    UUID().uuidString.replacingOccurrences(of: "-", with: "")
                )
            }
        )
    }

    /// Every caller receives an independent stream. This is required because one shared
    /// runtime can be a mandatory component of multiple data attachments.
    package nonisolated func terminationEvents() -> AsyncStream<TmuxControlClientTermination> {
        terminationBroadcaster.stream()
    }

    package var isReady: Bool {
        get async { await client.isReady }
    }

    package var capabilities: TmuxNegotiatedCapabilities {
        negotiatedCapabilities
    }

    package var configuration: TmuxControlClientConfiguration {
        clientConfiguration
    }

    package func start(timeout: Duration = .seconds(5)) async throws {
        await client.start()
        try await client.waitUntilReady(timeout: timeout)
        await negotiateCapabilities()
    }

    package func execute(
        _ operation: TmuxOperation,
        timeout: Duration
    ) async throws -> TmuxControlCommandResult {
        try await client.execute(operation, timeout: timeout)
    }

    package func readyExecutor(
        for request: TmuxOperationRequest
    ) async throws -> (any TmuxControlOperationExecuting)? {
        guard request.scope == scope, await client.isReady else { return nil }
        return TmuxControlClientOperationExecutor(client: client, scope: scope)
    }

    package func loadSnapshot(
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>,
        controlClientID: TmuxClientID?,
        timeout: Duration
    ) async throws -> TmuxServerSnapshot {
        _ = reason
        var snapshot = try await snapshotLoader.load(
            scope: scope,
            dialect: dialect,
            identities: identities,
            controlClientID: controlClientID,
            timeout: timeout
        )
        let changed = await reconcileDataClientFocusPolicies(
            identities: identities,
            snapshot: snapshot
        )
        if changed {
            snapshot = try await snapshotLoader.load(
                scope: scope,
                dialect: dialect,
                identities: identities,
                controlClientID: controlClientID,
                timeout: timeout
            )
        }
        return snapshot
    }

    package func setControlClientID(_ clientID: TmuxClientID) {
        controlClientID = clientID
    }

    /// Visibility, not attachment count, decides whether this exact interactive client
    /// participates in tmux size arbitration. A visible client is redrawn only after its
    /// PTY has been resized by the attachment.
    package func updateDataClientViewport(
        _ identity: TmuxControlInteractiveIdentity,
        isVisible: Bool
    ) async throws {
        let target = try TmuxClientTarget(identity.clientID.targetName)
        if negotiatedCapabilities.supportedClientFlags.contains(.ignoreSize) {
            let update = TmuxClientFlagUpdate(
                client: target,
                flag: .ignoreSize,
                enabled: !isVisible
            )
            let request = try TmuxControlRequest(
                renderedCommand: TmuxControlCommandRenderer().render(update),
                semantics: .idempotentMutation
            )
            guard try await client.execute(request, timeout: .seconds(2)).status == .succeeded
            else { throw TmuxInteractionError.clientUnavailable }
        }
        guard isVisible else { return }
        let redraw = try TmuxControlRequest(
            renderedCommand: TmuxControlCommandRenderer().renderClientRedraw(target),
            semantics: .idempotentMutation
        )
        guard try await client.execute(redraw, timeout: .seconds(2)).status == .succeeded
        else { throw TmuxInteractionError.clientUnavailable }
    }

    package func demandChanged(_ demand: TmuxControlHubDemand) async {
        // The attachment owns this runtime for the duration of the data channel. A
        // later provider runtime registry can use demand to evict the shared control
        // client; keeping this method a no-op here preserves the independent data-plane
        // lifetime and avoids closing Control Mode while a caller is reconciling state.
        _ = demand
    }

    package func close() async {
        await client.close()
        eventContinuation.finish()
    }

    /// Control Mode has no portable version-to-feature table. Probe each optional client
    /// flag against the ready client, then separately record only the safe configuration
    /// that this exact client enabled successfully.
    private func negotiateCapabilities() async {
        var supportedFlags = Set<TmuxClientFlag>()
        for flag in TmuxClientFlag.allCases {
            let command = "refresh-client -f !\(flag.rawValue)"
            if await executeNegotiationProbe(command) {
                supportedFlags.insert(flag)
            }
        }

        let subscriptionName = "__conn_capability_probe__"
        let subscriptionCommand = "refresh-client -B \(subscriptionName)::#{client_id}"
        let subscriptionAdded = await executeNegotiationProbe(subscriptionCommand)
        let subscriptionRemoved = subscriptionAdded
            ? await executeNegotiationProbe("refresh-client -B \(subscriptionName)")
            : false

        var enabledFlags = Set<TmuxClientFlag>()
        for flag in [TmuxClientFlag.noOutput, .waitExit, .ignoreSize]
            where supportedFlags.contains(flag)
        {
            if await executeNegotiationProbe("refresh-client -f \(flag.rawValue)") {
                enabledFlags.insert(flag)
                if flag == .waitExit {
                    await client.enableWaitExitHandshake(timeout: .seconds(1))
                }
            }
        }

        var activeSubscriptions = Set<String>()
        if subscriptionAdded && !subscriptionRemoved {
            activeSubscriptions.insert(subscriptionName)
        }
        if subscriptionAdded {
            let subscriptions = [
                ("__conn_session_attached__", "", "#{session_attached}"),
                ("__conn_pane_title__", "%*", "#{pane_title}"),
                ("__conn_pane_current_command__", "%*", "#{pane_current_command}"),
                ("__conn_pane_current_path__", "%*", "#{pane_current_path}"),
            ]
            for (name, target, format) in subscriptions {
                if await executeNegotiationProbe(
                    "refresh-client -B \(name):\(target):\(format)"
                ) {
                    activeSubscriptions.insert(name)
                }
            }
        }

        negotiatedCapabilities = TmuxNegotiatedCapabilities(
            supportedClientFlags: supportedFlags,
            supportsFormatSubscriptions: subscriptionAdded
        )
        clientConfiguration = TmuxControlClientConfiguration(
            enabledClientFlags: enabledFlags,
            activeSubscriptionNames: activeSubscriptions
        )
    }

    private func executeNegotiationProbe(_ command: String) async -> Bool {
        do {
            let request = try TmuxControlRequest(
                renderedCommand: TmuxRenderedControlCommand(value: command),
                semantics: .idempotentMutation
            )
            let result = try await client.execute(request, timeout: .seconds(1))
            return result.status == .succeeded
        } catch {
            return false
        }
    }

    private func reconcileDataClientFocusPolicies(
        identities: Set<TmuxControlInteractiveIdentity>,
        snapshot: TmuxServerSnapshot
    ) async -> Bool {
        let supportsActivePane = negotiatedCapabilities.supportedClientFlags.contains(.activePane)
        var changed = false
        for identity in identities.sorted(by: { $0.attachmentID < $1.attachmentID }) {
            if TmuxDataClientFocusPolicy.shouldEnableActivePane(
                for: identity,
                clients: snapshot.clients,
                supportsActivePane: supportsActivePane
            ) {
                changed = await applyDataClientFlag(
                    .activePane,
                    enabled: true,
                    to: identity
                ) || changed
            }
        }
        return changed
    }

    private func applyDataClientFlag(
        _ flag: TmuxClientFlag,
        enabled: Bool,
        to identity: TmuxControlInteractiveIdentity
    ) async -> Bool {
        do {
            let update = TmuxClientFlagUpdate(
                client: try TmuxClientTarget(identity.clientID.targetName),
                flag: flag,
                enabled: enabled
            )
            let request = try TmuxControlRequest(
                renderedCommand: TmuxControlCommandRenderer().render(update),
                semantics: .idempotentMutation
            )
            let result = try await client.execute(request, timeout: .seconds(2))
            return result.status == .succeeded
        } catch {
            // Keep the last verified topology and retry on the next reconciliation.
            // Failure must never make Conn assume that isolation was applied.
            return false
        }
    }
}

extension TmuxControlRuntime: TmuxReadyControlClientLocating {}
extension TmuxControlRuntime: TmuxDataClientViewportUpdating {}
extension TmuxControlRuntime: TmuxControlHubSnapshotLoading {
    package func loadSnapshot(
        scope requestedScope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot {
        guard requestedScope == scope else {
            throw TmuxControlHubRuntimeAdapterError.scopeMismatch(
                expected: scope,
                actual: requestedScope
            )
        }
        return try await loadSnapshot(
            reason: reason,
            identities: identities,
            controlClientID: controlClientID,
            timeout: .seconds(15)
        )
    }
}
extension TmuxControlRuntime: TmuxControlRuntimeLifecycleDriving {}
