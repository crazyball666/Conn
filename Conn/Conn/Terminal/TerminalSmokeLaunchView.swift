#if DEBUG
import ConnKit
import ConnTerminal
import ConnUI
import SwiftUI

struct TerminalSmokeLaunchView: View {
    let host: Host
    let dependencies: AppDependencies
    let terminalSessions: TerminalSessionCoordinator
    let initialCommand: String

    @State private var launcher: TerminalLaunchPresentation
    @State private var didStart = false

    init(
        host: Host,
        dependencies: AppDependencies,
        terminalSessions: TerminalSessionCoordinator,
        initialCommand: String
    ) {
        self.host = host
        self.dependencies = dependencies
        self.terminalSessions = terminalSessions
        self.initialCommand = initialCommand
        _launcher = State(initialValue: TerminalLaunchPresentation(
            hostRepository: dependencies.hostRepository,
            coordinator: terminalSessions
        ))
    }

    var body: some View {
        ProgressView(L("正在打开终端…"))
            .task {
                guard !didStart else { return }
                didStart = true
                launcher.launch(TerminalLaunchRequest(
                    host: host,
                    policy: .createNew,
                    source: .shell,
                    initialCommand: initialCommand
                ))
            }
            .fullScreenCover(item: $launcher.route) { route in
                TerminalScreen(
                    host: route.host,
                    tabID: route.tabID,
                    dependencies: dependencies,
                    terminalSessions: terminalSessions
                )
            }
    }
}
#endif
