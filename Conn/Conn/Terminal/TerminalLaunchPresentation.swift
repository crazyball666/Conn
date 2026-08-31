import ConnKit
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
@Observable
@MainActor
final class TerminalLaunchPresentation {
    private let hostRepository: any HostRepository
    private let coordinator: TerminalSessionCoordinator
    private var activeModel: ExplicitTerminalLaunchModel?
    private var activeLaunchToken: UUID?

    private(set) var isLaunching = false
    private(set) var errorMessage: String?
    var route: ExistingTerminalRoute?

    init(dependencies: AppDependencies) {
        hostRepository = dependencies.hostRepository
        coordinator = dependencies.terminalSessions
    }

    init(
        hostRepository: any HostRepository,
        coordinator: TerminalSessionCoordinator
    ) {
        self.hostRepository = hostRepository
        self.coordinator = coordinator
    }

    func launch(_ request: TerminalLaunchRequest) {
        guard activeModel == nil else { return }
        errorMessage = nil
        isLaunching = true
        let launchToken = UUID()
        let model = ExplicitTerminalLaunchModel(
            hostRepository: hostRepository,
            coordinator: coordinator,
            onCompleted: { [weak self] completion in
                guard let self,
                      activeLaunchToken == launchToken,
                      activeModel != nil
                else { return }
                activeLaunchToken = nil
                activeModel = nil
                isLaunching = false
                route = ExistingTerminalRoute(host: completion.host, tabID: completion.tabID)
            }
        )
        activeLaunchToken = launchToken
        activeModel = model
        Task { [weak self, weak model] in
            guard let self, let model else { return }
            await model.launch(request)
            guard activeLaunchToken == launchToken, activeModel === model else { return }
            activeLaunchToken = nil
            errorMessage = model.errorMessage
            isLaunching = false
            activeModel = nil
        }
    }

    func cancel() {
        guard let model = activeModel else { return }
        model.closeImmediately()
        activeLaunchToken = nil
        activeModel = nil
        isLaunching = false
    }
}
