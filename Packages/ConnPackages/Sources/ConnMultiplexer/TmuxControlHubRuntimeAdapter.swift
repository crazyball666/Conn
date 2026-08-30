import ConnSSH
import Foundation

package enum TmuxControlHubRuntimeAdapterError: Error, Sendable, Equatable {
    case invalidTimeout
    case scopeMismatch(expected: TmuxOperationScope, actual: TmuxOperationScope)
    case staleGeneration(current: UInt64, requested: UInt64)
    case controlClientNotReady
    case invalidExecutionResult
    case snapshotTokenMismatch
}

package struct TmuxControlOperationExecution: Sendable, Equatable {
    package let scope: TmuxOperationScope
    package let request: TmuxOperationRequest
    package let output: [Data]

    package init(
        scope: TmuxOperationScope,
        request: TmuxOperationRequest,
        output: [Data]
    ) {
        self.scope = scope
        self.request = request
        self.output = output
    }
}

/// An exact-generation Control Mode operation route. Implementations must return the same
/// request and scope they executed so the runtime adapter can fail closed on a stale route.
package protocol TmuxControlOperationExecuting: Sendable {
    func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration
    ) async throws -> TmuxControlOperationExecution
}

/// Locates only a ready Control Mode executor for the request's complete runtime scope.
package protocol TmuxReadyControlClientLocating: Sendable {
    func readyExecutor(
        for request: TmuxOperationRequest
    ) async throws -> (any TmuxControlOperationExecuting)?
}

package protocol TmuxControlHubSnapshotLoading: Sendable {
    func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot
}

package protocol TmuxControlRuntimeLifecycleDriving: Sendable {
    func demandChanged(_ demand: TmuxControlHubDemand) async
}

package protocol TmuxDataClientViewportUpdating: Sendable {
    func updateDataClientViewport(
        _ identity: TmuxControlInteractiveIdentity,
        isVisible: Bool
    ) async throws
}

/// Concrete bridge from an exact ready Control Mode client to the Hub runtime seam.
package struct TmuxControlClientOperationExecutor: TmuxControlOperationExecuting {
    private let client: TmuxControlClient
    private let scope: TmuxOperationScope

    package init(client: TmuxControlClient, scope: TmuxOperationScope) {
        self.client = client
        self.scope = scope
    }

    package func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration
    ) async throws -> TmuxControlOperationExecution {
        guard request.scope == scope else {
            throw TmuxControlHubRuntimeAdapterError.scopeMismatch(
                expected: scope,
                actual: request.scope
            )
        }
        guard await client.isReady else {
            throw TmuxControlHubRuntimeAdapterError.controlClientNotReady
        }
        guard await client.generation == scope.generation else {
            throw TmuxControlHubRuntimeAdapterError.staleGeneration(
                current: await client.generation,
                requested: scope.generation
            )
        }
        let result = try await client.execute(request.operation, timeout: timeout)
        guard result.generation == scope.generation,
              await client.generation == scope.generation
        else {
            throw TmuxControlHubRuntimeAdapterError.staleGeneration(
                current: await client.generation,
                requested: scope.generation
            )
        }
        return .init(scope: scope, request: request, output: result.output)
    }
}

/// Routes Hub work only to the required, already-ready Control Mode executor. Discovery
/// may use bounded one-shot reads before attachment startup, but an attached tmux runtime
/// never changes command transports after readiness.
package actor TmuxControlHubRuntimeAdapter: TmuxControlHubAdapter {
    private var currentScope: TmuxOperationScope
    private var latestDemandSequence: UInt64 = 0

    private let controlClients: any TmuxReadyControlClientLocating
    private let snapshots: any TmuxControlHubSnapshotLoading
    private let lifecycle: any TmuxControlRuntimeLifecycleDriving
    private let viewport: any TmuxDataClientViewportUpdating

    package init(
        initialScope: TmuxOperationScope,
        controlClients: any TmuxReadyControlClientLocating,
        snapshots: any TmuxControlHubSnapshotLoading,
        lifecycle: any TmuxControlRuntimeLifecycleDriving,
        viewport: any TmuxDataClientViewportUpdating
    ) {
        currentScope = initialScope
        self.controlClients = controlClients
        self.snapshots = snapshots
        self.lifecycle = lifecycle
        self.viewport = viewport
    }

    package func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxControlHubOperationReceipt {
        guard timeout > .zero else {
            throw TmuxControlHubRuntimeAdapterError.invalidTimeout
        }
        try accept(scope: request.scope)
        _ = identities

        guard let control = try await controlClients.readyExecutor(for: request) else {
            throw TmuxControlHubRuntimeAdapterError.controlClientNotReady
        }
        let execution = try await control.execute(request, timeout: timeout)
        try validate(execution, for: request)
        try ensureCurrent(scope: request.scope)
        return TmuxControlHubOperationReceipt(
            request: request,
            output: execution.output
        )
    }

    package func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot {
        try accept(scope: scope)
        let snapshot = try await snapshots.loadSnapshot(
            scope: scope,
            reason: reason,
            identities: identities
        )
        guard snapshot.instance.token == scope.instanceToken else {
            throw TmuxControlHubRuntimeAdapterError.snapshotTokenMismatch
        }
        try ensureCurrent(scope: scope)
        return snapshot
    }

    package func updateDataClientViewport(
        scope: TmuxOperationScope,
        identity: TmuxControlInteractiveIdentity,
        isVisible: Bool
    ) async throws {
        try accept(scope: scope)
        try await viewport.updateDataClientViewport(identity, isVisible: isVisible)
        try ensureCurrent(scope: scope)
    }

    package func demandChanged(_ demand: TmuxControlHubDemand) async {
        guard demand.sequence > latestDemandSequence else { return }
        guard isSameRuntime(scope: demand.scope, as: currentScope) else { return }
        guard demand.scope.generation >= currentScope.generation else { return }

        latestDemandSequence = demand.sequence
        currentScope = demand.scope
        await lifecycle.demandChanged(demand)
    }

    private func accept(scope: TmuxOperationScope) throws {
        guard isSameRuntime(scope: scope, as: currentScope) else {
            throw TmuxControlHubRuntimeAdapterError.scopeMismatch(
                expected: currentScope,
                actual: scope
            )
        }
        guard scope.generation >= currentScope.generation else {
            throw TmuxControlHubRuntimeAdapterError.staleGeneration(
                current: currentScope.generation,
                requested: scope.generation
            )
        }
        if scope.generation > currentScope.generation {
            currentScope = scope
        }
    }

    private func ensureCurrent(scope: TmuxOperationScope) throws {
        guard isSameRuntime(scope: scope, as: currentScope) else {
            throw TmuxControlHubRuntimeAdapterError.scopeMismatch(
                expected: currentScope,
                actual: scope
            )
        }
        guard currentScope.generation == scope.generation else {
            throw TmuxControlHubRuntimeAdapterError.staleGeneration(
                current: currentScope.generation,
                requested: scope.generation
            )
        }
    }

    private func validate(
        _ execution: TmuxControlOperationExecution,
        for request: TmuxOperationRequest
    ) throws {
        guard execution.scope == request.scope,
              execution.request == request
        else {
            throw TmuxControlHubRuntimeAdapterError.invalidExecutionResult
        }
    }

    private func isSameRuntime(
        scope: TmuxOperationScope,
        as other: TmuxOperationScope
    ) -> Bool {
        scope.connectionIdentity == other.connectionIdentity
            && scope.configurationKey == other.configurationKey
            && scope.instanceToken == other.instanceToken
    }

}
