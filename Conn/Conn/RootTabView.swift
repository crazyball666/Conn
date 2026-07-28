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
    @State private var backgroundedAt: Date?
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    /// 每个 Tab 各自一个 `NavigationStack`（SwiftUI 标准结构）——各首页由此获得系统导航栏
    /// （大标题 + 系统搜索 `.searchable` + 右上角 toolbar 图标）；这些修饰只有挂在各自栈内的
    /// 内容上才会生效，`TabView` 嵌在单一外层栈里时不会冒泡。
    ///
    /// push 详情页时**底栏常驻**（系统 App 标准做法：App Store / 音乐 / 播客 皆如此）——
    /// 底栏不移动，故返回无延迟。系统原生底栏：iOS 26 液态玻璃、深浅色随系统。
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
            switch phase {
            case .background:
                // 不 stop()：iOS 本就挂起 App，轮询 Task 自然停止推进，没有额外耗电；
                // 而 onAppear 回前台不保证重新触发，停了就再也起不来。
                backgroundedAt = Date()
            case .active:
                guard let at = backgroundedAt else { break }
                let idle = Date().timeIntervalSince(at)
                backgroundedAt = nil
                Task { await dependencies.monitor.resumeAfterBackground(idleFor: idle) }
            default:
                break
            }
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
