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

    /// 单一 `NavigationStack` 包裹整个 `TabView`——push 子页时**整块界面（含底栏）
    /// 作为一层被推走**，而不是把底栏当独立层去隐藏（那会导致返回动画结束后底栏才
    /// 迟迟出现）。系统原生底栏：iOS 26 液态玻璃、深浅色随系统。
    ///
    /// 各 Tab 首页自绘标题，故在根层隐藏系统 nav bar；push 出去的子页各自带回退
    /// nav bar。子页的 navigationDestination/NavigationLink 就近挂到这唯一的外层栈。
    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                tab(.servers) { ServersView(dependencies: dependencies) }
                tab(.terminal) { TerminalCenterView(store: terminalStore, dependencies: dependencies) }
                tab(.commands) { SnippetsView(dependencies: dependencies) }
                tab(.me) { MeView(dependencies: dependencies) }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func tab(
        _ tab: ConnDock.Tab,
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
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
