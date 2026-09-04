import ConnEntitlement
import ConnKit
import ConnMonitor
import ConnTerminal
import ConnUI
import SwiftUI

/// 主机工作台：概览是落地页，进程 / 文件 / Docker / 日志作为独立目的地进入。
///
/// 各 ViewModel 仍在工作台级持有——从模块返回时不会丢失已加载数据；进入工作台后
/// 保留 App 底栏，用户可以直接切换到命令或设置 Tab。
struct HostDetailView: View {
    let host: Host
    let dependencies: AppDependencies
    @State private var route: Segment?
    @State private var monitorVM: HostOverviewViewModel
    @State private var processVM: ProcessListViewModel
    // 各模块 VM 在工作台级持有——离页停止任务，但返回时仍可先显示缓存再刷新。
    @State private var fileVM: FileBrowserViewModel
    @State private var dockerVM: DockerViewModel
    @State private var logVM: LogCenterViewModel
    @State private var terminalRoute: ExistingTerminalRoute?
    @State private var isNewTerminalPresented = false
    @State private var pendingTerminalCompletion: NewTerminalFlowCompletion?
    @State private var paywallContext: PaywallContext?
    private let initialSegment: Segment
    @Environment(SettingsStore.self) private var settings
    @Environment(\.connToastCenter) private var toastCenter

    init(host: Host, dependencies: AppDependencies, initialSegment: Segment = .overview) {
        self.host = host
        self.dependencies = dependencies
        self.initialSegment = initialSegment
        _route = State(initialValue: initialSegment == .overview ? nil : initialSegment)
        _monitorVM = State(initialValue: HostOverviewViewModel(host: host, dependencies: dependencies))
        _processVM = State(initialValue: ProcessListViewModel(host: host, dependencies: dependencies))
        _fileVM = State(initialValue: FileBrowserViewModel(host: host, dependencies: dependencies))
        _dockerVM = State(initialValue: DockerViewModel(host: host, dependencies: dependencies))
        _logVM = State(initialValue: LogCenterViewModel(host: host, dependencies: dependencies))
    }

    enum Segment: String, CaseIterable, Hashable, Identifiable {
        case overview = "概览"
        case processes = "进程"
        case files = "文件"
        case docker = "Docker"
        case logs = "日志"
        var id: String { rawValue }
    }

    var body: some View {
        HostOverviewView(viewModel: monitorVM) {
            toolGrid
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.top, ConnSpacing.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { terminalToolbarItem }
        .toolbar(.visible, for: .tabBar)
        .navigationDestination(item: $route, destination: destination)
        .onAppear {
            presentPaywallIfNeededForInitialRoute()
            monitorVM.appear()
        }
        .onDisappear { monitorVM.disappear() }
        .sheet(
            isPresented: $isNewTerminalPresented,
            onDismiss: openPendingTerminal
        ) {
            NewTerminalSheet(
                fixedHost: host,
                hostRepository: dependencies.hostRepository,
                terminalSessions: dependencies.terminalSessions,
                onCompleted: { completion in
                    pendingTerminalCompletion = completion
                    isNewTerminalPresented = false
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $paywallContext) { context in
            PaywallView(dependencies: dependencies, context: context)
        }
        .fullScreenCover(item: $terminalRoute) { route in
            TerminalScreen(
                host: route.host,
                tabID: route.tabID,
                dependencies: dependencies,
                settings: settings
            )
        }
    }

    /// 终端入口：导航栏右上角图标，弹出终端会话（无中间落地页）。
    @ToolbarContentBuilder
    private var terminalToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                openTerminal()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .semibold))
            }
            .accessibilityLabel(L("打开终端"))
            .accessibilityIdentifier("host.open-terminal")
        }
    }

    private func openTerminal() {
        if let recent = dependencies.terminalSessions.store.recentTab(forHost: host.id) {
            terminalRoute = ExistingTerminalRoute(host: host, tabID: recent.id)
        } else {
            isNewTerminalPresented = true
        }
    }

    private func openPendingTerminal() {
        guard let completion = pendingTerminalCompletion else { return }
        pendingTerminalCompletion = nil
        toastCenter.show(completion.notice, style: .success)
        terminalRoute = ExistingTerminalRoute(host: completion.host, tabID: completion.tabID)
    }

    /// 导航栏始终显示主机名称。
    private var displayTitle: String { host.name }

    private var toolGrid: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("操作"))
                .font(.connCaption)
                .foregroundStyle(.connMuted)
                .connEyebrowTracking()
            HStack(spacing: ConnSpacing.xs) {
                toolButton(.processes, systemImage: "waveform.path.ecg")
                toolButton(.files, systemImage: "doc")
                toolButton(.docker, systemImage: "shippingbox")
                toolButton(.logs, systemImage: "list.bullet.rectangle")
            }
        }
    }

    private func toolButton(_ segment: Segment, systemImage: String) -> some View {
        ActionTile(L(segment.rawValue), systemName: systemImage) {
            guard requireProIfNeeded(for: segment) else { return }
            route = segment
        }
    }

    private func presentPaywallIfNeededForInitialRoute() {
        guard initialSegment != .overview else { return }
        guard !requireProIfNeeded(for: initialSegment) else { return }
        route = nil
    }

    private func requireProIfNeeded(for segment: Segment) -> Bool {
        switch segment {
        case .files where !dependencies.subscription.gate.allowed(.fileManagement):
            paywallContext = .fileManagement
            return false
        case .docker where !dependencies.subscription.gate.allowed(.dockerManagement):
            paywallContext = .dockerManagement
            return false
        default:
            return true
        }
    }

    @ViewBuilder
    private func destination(_ segment: Segment) -> some View {
        switch segment {
        case .overview:
            modulePage {
                HostOverviewView(viewModel: monitorVM) { EmptyView() }
            }
            .navigationTitle(displayTitle)
        case .processes:
            modulePage { ProcessListView(viewModel: processVM) }
                .navigationTitle(L("进程"))
        case .files:
            modulePage(showsTerminal: false) {
                FileBrowserView(host: host, dependencies: dependencies, viewModel: fileVM)
            }
            .navigationTitle(L("文件"))
        case .docker:
            modulePage(showsTerminal: false) {
                DockerView(host: host, dependencies: dependencies, viewModel: dockerVM)
            }
        case .logs:
            modulePage {
                LogCenterView(host: host, dependencies: dependencies, viewModel: logVM)
            }
            .navigationTitle(L("日志"))
        }
    }

    private func modulePage<Content: View>(
        showsTerminal: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, ConnSpacing.page)
            .padding(.top, ConnSpacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.connBg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsTerminal { terminalToolbarItem }
            }
            .toolbar(.visible, for: .tabBar)
    }
}
