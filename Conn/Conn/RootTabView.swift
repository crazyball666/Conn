import ConnAnalytics
import ConnKit
import ConnMonitor
import ConnPrivateNetwork
import ConnTerminal
import ConnUI
import SwiftUI

/// App 根导航：服务器、终端、脚本、设置。
struct RootTabView: View {
    @State private var selection: ConnDock.Tab = .servers
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationManager.self) private var localization
    /// 前后台判定抽在 `BackgroundResumePolicy` 里（可单测）；View 只负责转发事件、
    /// 拿到闲置时长后发起恢复。
    @State private var resumePolicy = BackgroundResumePolicy()
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    /// 每个 Tab 各自一个 `NavigationStack`（SwiftUI 标准结构）——各首页由此获得系统导航栏
    /// （大标题 + 系统搜索 `.searchable` + 右上角 toolbar 图标）；这些修饰只有挂在各自栈内的
    /// 内容上才会生效，`TabView` 嵌在单一外层栈里时不会冒泡。
    ///
    /// 根列表和主机工作区都使用系统原生底栏，详情页也可以直接切换到其它 Tab。
    var body: some View {
        TabView(selection: $selection) {
            tab(.servers) {
                NavigationStack { ServersView(dependencies: dependencies) }
            }
            tab(.terminal) {
                NavigationStack { TerminalSessionCenterView(dependencies: dependencies) }
            }
            tab(.commands) {
                NavigationStack { SnippetsView(dependencies: dependencies) }
            }
            tab(.me) {
                NavigationStack { MeView(dependencies: dependencies) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await dependencies.subscription.refresh() }
            }
            guard let idle = resumePolicy.idleDurationOnResume(for: phase) else { return }
            Task {
                // 私有网络先清理/释放 stale runtime，再恢复监控和终端。顺序反过来
                // 会让终端重连先复用后台挂起后的旧 Tailscale 节点，直到 Citadel
                // 的 25s 超时才失败，随后才执行清理。
                await dependencies.privateNetworkRegistry.resumeAfterBackground(idleFor: idle)
                await dependencies.monitor.resumeAfterBackground(idleFor: idle)
                await dependencies.terminalSessions.resumeAfterBackground(idleFor: idle)
            }
        }
        .onChange(of: selection) { _, _ in
            trackScreen()
        }
        .onChange(of: settings.appearance) { _, _ in
            updateAnalyticsContext()
        }
        .onChange(of: localization.language) { _, _ in
            updateAnalyticsContext()
        }
        .onChange(of: dependencies.subscription.isPro) { _, _ in
            updateAnalyticsContext()
        }
        .onAppear {
            trackScreen()
            updateAnalyticsContext()
        }
    }

    private func trackScreen() {
        Analytics.shared.track(.screenViewed, [.screen: selection.rawValue])
    }

    private func updateAnalyticsContext() {
        Analytics.updateContext(
            appearance: settings.appearance.rawValue,
            locale: localization.language.rawValue,
            tier: dependencies.subscription.isPro ? "pro" : "free"
        )
    }

    private func tab(
        _ tab: ConnDock.Tab,
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
            .tabItem {
                Label(L(tab.title), systemImage: tab.systemImage)
                    .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
            .tag(tab)
    }
}

/// 尚未实现的 Tab 占位屏。
struct PlaceholderScreen: View {
    let title: String
    let systemName: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: title)
            Spacer()
            EmptyState(systemName: systemName, title: title, message: message)
            Spacer()
        }
    }
}

/// 页面标题区。
struct ScreenHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.connTitle)
                .connDisplayTracking()
                .foregroundStyle(.connInk)
            if let subtitle {
                Text(subtitle)
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ConnSpacing.page)
        .padding(.top, ConnSpacing.xs)
        .padding(.bottom, ConnSpacing.sm)
    }
}
