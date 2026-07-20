import SwiftUI

/// 快捷动作方块。
///
/// 设计规范 §5：方块网格、SF Symbol + 标签、按下缩放。图标恒为品牌色。
/// 用于仪表盘快捷入口、单机详情动作区、运维工具箱。
public struct ActionTile: View {
    private let title: String
    private let systemName: String
    private let isSelected: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        systemName: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemName = systemName
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.connAccent)
                Text(title)
                    .font(.connData(.caption))
                    .foregroundStyle(.connInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: ConnSize.actionTile)
            .connSurface(
                cornerRadius: ConnRadius.card,
                borderColor: isSelected ? .connAccent.opacity(0.5) : nil
            )
        }
        .buttonStyle(ConnPressStyle())
    }
}

/// 空态。
///
/// 设计规范 §5：SF Symbol + 一句话 + 主按钮；**首屏空态必须给双出口**
/// （「添加主机 / 试试演示」）。原型未出稿此组件，按规范文字实现。
public struct EmptyState: View {
    private let systemName: String
    private let title: String
    private let message: String?
    private let primary: Action?
    private let secondary: Action?

    /// 一个出口。
    public struct Action {
        let title: String
        let handler: () -> Void

        public init(_ title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    public init(
        systemName: String,
        title: String,
        message: String? = nil,
        primary: Action? = nil,
        secondary: Action? = nil
    ) {
        self.systemName = systemName
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        VStack(spacing: ConnSpacing.sm) {
            Image(systemName: systemName)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.connMuted)
                .padding(.bottom, ConnSpacing.xxs)

            Text(title)
                .font(.connSectionTitle)
                .foregroundStyle(.connInk)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
                    .multilineTextAlignment(.center)
            }

            if let primary {
                ConnButton(primary.title, action: primary.handler)
                    .padding(.top, ConnSpacing.xs)
            }
            if let secondary {
                ConnButton(secondary.title, kind: .ghost, action: secondary.handler)
            }
        }
        .padding(.horizontal, ConnSpacing.xl)
        .frame(maxWidth: .infinity)
    }
}

#Preview("ActionTile · 深色") {
    VStack(spacing: ConnSpacing.md) {
        LazyVGrid(columns: Array(repeating: GridItem(spacing: ConnSpacing.xs), count: 3), spacing: ConnSpacing.xs) {
            ActionTile("全部巡检", systemName: "arrow.clockwise") {}
            ActionTile("批量执行", systemName: "square.stack.3d.up") {}
            ActionTile("演示模式", systemName: "play.rectangle") {}
        }
        LazyVGrid(columns: Array(repeating: GridItem(spacing: ConnSpacing.xs), count: 4), spacing: ConnSpacing.xs) {
            ActionTile("终端", systemName: "terminal", isSelected: true) {}
            ActionTile("日志", systemName: "doc.text") {}
            ActionTile("重启 nginx", systemName: "arrow.triangle.2.circlepath") {}
            ActionTile("清理磁盘", systemName: "trash") {}
        }
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("EmptyState · 双主题") {
    VStack(spacing: 0) {
        ForEach([ColorScheme.dark, .light], id: \.self) { scheme in
            EmptyState(
                systemName: "server.rack",
                title: "还没有主机",
                message: "添加第一台服务器，或先用演示模式逛一圈",
                primary: .init("添加我的服务器") {},
                secondary: .init("先逛逛演示模式") {}
            )
            .padding(.vertical, ConnSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.connBg)
            .environment(\.colorScheme, scheme)
        }
    }
}
