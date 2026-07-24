import ConnKit
import ConnTerminal
import ConnUI
import SwiftUI

/// App 根导航：5 Tab + 悬浮 Dock。
///
/// 设计规范 §4：5 Tab（仪表盘/主机/终端/命令/我的）。用自绘 `ConnDock` 而非
/// 系统 `TabView`，因为原型的 Dock 是悬浮圆角样式，系统 TabBar 无法做到。
struct RootTabView: View {
    @State private var selection: ConnDock.Tab = .servers
    /// 终端会话 store 提到根层，切走终端 Tab 时会话仍存活（后台保持）。
    @State private var terminalStore = TerminalSessionStore()
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    /// 系统原生 `TabView`——iOS 26 自动带液态玻璃底栏，深浅色随系统。
    ///
    /// 每个 Tab 各包一层 `NavigationStack`（push 导航前提；根内容自绘标题故隐藏
    /// 系统 nav bar）。子页面用 `.toolbar(.hidden, for: .tabBar)` 隐藏底栏——
    /// 底栏只在各 Tab 首页出现（见各 push 目的地）。
    var body: some View {
        TabView(selection: $selection) {
            tab(.servers) { ServersView(dependencies: dependencies) }
            tab(.terminal) { TerminalCenterView(store: terminalStore, dependencies: dependencies) }
            tab(.commands) { SnippetsView(dependencies: dependencies) }
            tab(.me) { MeView(dependencies: dependencies) }
        }
    }

    private func tab(
        _ tab: ConnDock.Tab,
        @ViewBuilder content: () -> some View
    ) -> some View {
        NavigationStack {
            content()
                .toolbar(.hidden, for: .navigationBar)
        }
        .tabItem { Label(L(tab.title), systemImage: tab.systemImage) }
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
