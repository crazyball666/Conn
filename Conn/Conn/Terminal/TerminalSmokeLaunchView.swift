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
        @State private var didScheduleReconnect = false
        @State private var didReconnect = false
        @Environment(SettingsStore.self) private var settings

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
                    TerminalSmokeDestination(
                        host: route.host,
                        tabID: route.tabID,
                        dependencies: dependencies,
                        terminalSessions: terminalSessions,
                        settings: settings,
                        didReconnect: didReconnect
                    )
                }
                .onChange(of: launcher.route?.tabID) { _, tabID in
                    guard !didScheduleReconnect,
                          let tabID,
                          ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_RECONNECT"] != nil
                    else { return }
                    didScheduleReconnect = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        if case .success = await terminalSessions.reconnect(tabID) {
                            didReconnect = true
                        }
                    }
                }
        }
    }

    /// Seeds one deterministic local tab so UI tests can inspect the terminal-center card itself.
    struct TerminalSessionCenterSmokeView: View {
        let dependencies: AppDependencies

        @State private var didSeed = false

        var body: some View {
            TerminalSessionCenterView(dependencies: dependencies)
                .task {
                    guard !didSeed else { return }
                    didSeed = true
                    if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_RESUME"] != nil {
                        return
                    }
                    guard let hosts = try? dependencies.hostRepository.allHosts(),
                          let host = hosts.first
                    else { return }
                    _ = await dependencies.terminalSessions.launch(TerminalLaunchRequest(
                        host: host,
                        policy: .createNew,
                        source: .shell
                    ))
                }
        }
    }

    /// UI tests may attach a deterministic provider interaction facet to the real terminal
    /// screen. Preparation happens before `TerminalScreen` is constructed so its
    /// `TerminalInputController` observes the facet from the first render.
    private struct TerminalSmokeDestination: View {
        let host: Host
        let tabID: String
        let dependencies: AppDependencies
        let terminalSessions: TerminalSessionCoordinator
        let settings: SettingsStore
        let didReconnect: Bool

        @State private var isPrepared = false

        var body: some View {
            if isPrepared {
                ZStack(alignment: .topLeading) {
                    TerminalScreen(
                        host: host,
                        tabID: tabID,
                        dependencies: dependencies,
                        settings: settings,
                        terminalSessions: terminalSessions
                    )
                    if didReconnect {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier("terminal.smoke.reconnect.completed")
                            .allowsHitTesting(false)
                    }
                }
            } else {
                ProgressView(L("正在打开终端…"))
                    .task {
                        if ProcessInfo.processInfo.environment["CONN_SMOKE_ZELLIJ_ACTIONS"] != nil {
                            TerminalZellijQuickActionSmokeSupport.install(
                                in: terminalSessions.store,
                                tabID: tabID
                            )
                        } else if ProcessInfo.processInfo.environment["CONN_SMOKE_TMUX_ACTIONS"] != nil {
                            TerminalTmuxQuickActionSmokeSupport.install(
                                in: terminalSessions.store,
                                tabID: tabID
                            )
                        }
                        isPrepared = true
                    }
            }
        }
    }
#endif
