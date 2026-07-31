import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI

/// App 根导航：3 Tab（服务器 / 命令 / 设置）。
///
/// 终端不再单独占一个 Tab——从主机详情右上角的终端图标进入（会话随详情栈存活）。
struct RootTabView: View {
    @State private var selection: ConnDock.Tab = .servers
    @Environment(\.scenePhase) private var scenePhase
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
    /// 根列表使用系统原生底栏；进入主机工作区等沉浸式详情后由目的页面隐藏底栏，
    /// 避免“App 导航 + 工作区导航”同时占据屏幕。
    var body: some View {
        TabView(selection: $selection) {
            tab(.servers) {
                NavigationStack { ServersView(dependencies: dependencies) }
            }
            tab(.commands) {
                NavigationStack { SnippetsView(dependencies: dependencies) }
            }
            tab(.me) {
                NavigationStack { MeView(dependencies: dependencies) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let idle = resumePolicy.idleDurationOnResume(for: phase) else { return }
            Task { await dependencies.monitor.resumeAfterBackground(idleFor: idle) }
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
