import ConnKit
import Foundation
import Observation

/// Source-page state for Docker/script/debug requests that already specify their
/// backend and initial command and therefore must not display a backend picker.
@Observable
@MainActor
public final class ExplicitTerminalLaunchModel {
    public private(set) var isLaunching = false
    public private(set) var errorMessage: String?

    private let operations: NewTerminalFlowModel.Operations
    @ObservationIgnored private let onCompleted: @MainActor (NewTerminalFlowCompletion) -> Void
    private var generation: UInt64 = 0
    private var activeAttemptID: TerminalLaunchAttemptID?
    private var closed = false
    private var didComplete = false

    public init(
        operations: NewTerminalFlowModel.Operations,
        onCompleted: @escaping @MainActor (NewTerminalFlowCompletion) -> Void
    ) {
        self.operations = operations
        self.onCompleted = onCompleted
    }

    public convenience init(
        hostRepository: any HostRepository,
        coordinator: TerminalSessionCoordinator,
        onCompleted: @escaping @MainActor (NewTerminalFlowCompletion) -> Void
    ) {
        self.init(
            operations: .live(hostRepository: hostRepository, coordinator: coordinator),
            onCompleted: onCompleted
        )
    }

    public func launch(_ request: TerminalLaunchRequest) async {
        guard !closed, !didComplete, !isLaunching else { return }
        generation &+= 1
        let launchGeneration = generation
        isLaunching = true
        errorMessage = nil

        let attemptID = operations.beginLaunchAttempt()
        activeAttemptID = attemptID
        switch await operations.prepareLaunch(request, attemptID) {
        case .success:
            guard isCurrent(launchGeneration, attemptID: attemptID) else {
                await operations.cancelLaunch(attemptID)
                return
            }
            switch await operations.commitLaunch(attemptID) {
            case let .success(tabID):
                guard isCurrent(launchGeneration, attemptID: attemptID) else { return }
                activeAttemptID = nil
                isLaunching = false
                didComplete = true
                onCompleted(NewTerminalFlowCompletion(host: request.host, tabID: tabID))
            case let .failure(failure):
                finishFailure(failure, generation: launchGeneration, attemptID: attemptID)
            }
        case let .failure(failure):
            finishFailure(failure, generation: launchGeneration, attemptID: attemptID)
        }
    }

    public func close() async {
        await closeImmediately()?.value
    }

    /// Marks the launch stale synchronously; coordinator cleanup may continue without
    /// holding the source page open.
    @discardableResult
    public func closeImmediately() -> Task<Void, Never>? {
        guard !closed else { return nil }
        closed = true
        generation &+= 1
        isLaunching = false
        guard let activeAttemptID else { return nil }
        self.activeAttemptID = nil
        return Task { @MainActor [operations] in
            await operations.cancelLaunch(activeAttemptID)
        }
    }

    private func isCurrent(
        _ expectedGeneration: UInt64,
        attemptID: TerminalLaunchAttemptID
    ) -> Bool {
        !closed && generation == expectedGeneration && activeAttemptID == attemptID
    }

    private func finishFailure(
        _ failure: TerminalLaunchFailure,
        generation expectedGeneration: UInt64,
        attemptID: TerminalLaunchAttemptID
    ) {
        guard isCurrent(expectedGeneration, attemptID: attemptID) else { return }
        activeAttemptID = nil
        isLaunching = false
        errorMessage = failure.message
    }
}
