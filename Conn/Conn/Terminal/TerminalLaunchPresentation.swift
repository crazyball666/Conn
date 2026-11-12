import ConnAnalytics
import ConnKit
import ConnMultiplexer
import ConnTerminal
import Foundation
import Observation

struct ExistingTerminalRoute: Identifiable {
    let host: Host
    let tabID: String

    var id: String { tabID }
}

/// Reusable source-page presentation state for requests that already specify their
/// source/backend/command (Docker and scripts).
///
/// The local tab is created before the remote connection completes, so the terminal
/// page opens immediately and the connection card is rendered there.
@Observable
@MainActor
final class TerminalLaunchPresentation {
    private let coordinator: TerminalSessionCoordinator
    private var activeLaunchToken: UUID?

    private(set) var isLaunching = false
    private(set) var errorMessage: String?
    var route: ExistingTerminalRoute?

    init(dependencies: AppDependencies) {
        coordinator = dependencies.terminalSessions
    }

    init(coordinator: TerminalSessionCoordinator) {
        self.coordinator = coordinator
    }

    func launch(_ request: TerminalLaunchRequest) {
        guard activeLaunchToken == nil else { return }
        errorMessage = nil
        isLaunching = true
        let token = UUID()
        activeLaunchToken = token
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await coordinator.startConnecting(request)
            guard activeLaunchToken == token else {
                if case let .success(tab) = result {
                    await coordinator.close(tab.id)
                }
                return
            }
            activeLaunchToken = nil
            isLaunching = false
            switch result {
            case let .success(tab):
                route = ExistingTerminalRoute(host: request.host, tabID: tab.id)
            case let .failure(failure):
                errorMessage = failure.message
                let provider: String
                switch request.backend {
                case .plainPTY: provider = "plain"
                case let .persistent(descriptor): provider = descriptor.providerID
                }
                Analytics.shared.track(.connectionFinished, [
                    .success: "false",
                    .provider: provider,
                    .errorCategory: "connection",
                    .hostRef: request.host.id,
                ])
                Analytics.shared.track(.errorOccurred, [
                    .area: "terminal",
                    .category: "connection",
                    .recoverable: "true",
                    .source: "terminal_launch",
                ])
            }
        }
    }

    func cancel() {
        guard route == nil else { return }
        activeLaunchToken = nil
        isLaunching = false
    }
}
