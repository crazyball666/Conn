import ConnKit
import ConnTerminal
import ConnUI
import SwiftUI

/// App 根导航：5 Tab + 悬浮 Dock。
///
/// 设计规范 §4：5 Tab（仪表盘/主机/终端/命令/我的）。用自绘 `ConnDock` 而非
/// 系统 `TabView`，因为原型的 Dock 是悬浮圆角样式，系统 TabBar 无法做到。
struct RootTabView: View {
    @State private var selection: ConnDock.Tab = .dashboard
    /// 终端会话 store 提到根层，切走终端 Tab 时会话仍存活（后台保持）。
    @State private var terminalStore = TerminalSessionStore()
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    var body: some View {
        content
            // safeAreaInset 是「内容 + 悬浮底栏」的惯用写法：把 Dock 的高度并入
            // 内容安全区，滚动内容不会被遮挡，也不必手写魔法数字。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ConnDock(selection: $selection)
            }
            .background(Color.connBg.ignoresSafeArea())
    }

    /// 各 Tab 的根内容。
    ///
    /// **每个 Tab 必须包一层 `NavigationStack`**：ScrollView 直接作为窗口根视图时
    /// 顶部 content inset 不生效，内容会顶进状态栏（已用红线基准实测确认）。
    /// NavigationStack 提供了正确的安全区容器；同时它也是后续 push 导航
    /// （主机→详情、我的→密钥管家）的前提，不是为绕开 bug 而加的补丁。
    ///
    /// 导航栏隐藏：原型各屏用的是自绘标题区（`ScreenHeader`），不用系统 nav bar。
    private var content: some View {
        NavigationStack {
            tabRoot
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var tabRoot: some View {
        switch selection {
        case .dashboard:
            DashboardView(dependencies: dependencies)
        case .hosts:
            HostListView(dependencies: dependencies)
        case .terminal:
            TerminalCenterView(store: terminalStore, dependencies: dependencies)
        case .commands:
            SnippetsView(dependencies: dependencies)
        case .me:
            MeView(dependencies: dependencies)
        }
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
