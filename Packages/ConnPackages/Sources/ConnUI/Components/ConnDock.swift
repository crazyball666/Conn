import SwiftUI

/// 底部 5 Tab 悬浮 Dock。
///
/// 设计规范 §5：距底 10pt、左右缩进 12pt、28pt 圆角、`connBar` 底 + 毛玻璃 + 细描边；
/// 选中项 accent 着色。原型受 HTML 限制未实现毛玻璃，此处按规范用
/// `.ultraThinMaterial` 落地（冲突台账 C31）。
public struct ConnDock: View {
    /// 五个根 Tab（信息架构 §5.0）。
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case dashboard, hosts, terminal, commands, me

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .dashboard: "仪表盘"
            case .hosts: "主机"
            case .terminal: "终端"
            case .commands: "命令"
            case .me: "我的"
            }
        }

        public var systemImage: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.33percent"
            case .hosts: "server.rack"
            case .terminal: "terminal"
            case .commands: "command"
            case .me: "person.crop.circle"
            }
        }
    }

    @Binding private var selection: Tab

    public init(selection: Binding<Tab>) {
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                tabButton(tab)
            }
        }
        .frame(height: ConnSize.dockHeight)
        .background(.ultraThinMaterial, in: shape)
        .background(Color.connBar.opacity(0.72), in: shape)
        .overlay(shape.strokeBorder(Color.connLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
        .padding(.horizontal, ConnSize.dockHorizontalInset)
        .padding(.bottom, ConnSize.dockBottomInset)
    }

    private var shape: RoundedRectangle {
        .rect(cornerRadius: ConnRadius.dock, style: .continuous)
    }

    private func tabButton(_ tab: Tab) -> some View {
        Button {
            // 高频操作不加动画（设计规范 §6：频率决定是否动画）
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: ConnSize.dockGlyph)
                Text(L(tab.title))
                    .font(.system(size: 11))
            }
            .foregroundStyle(selection == tab ? Color.connAccent : .connMuted)
            .frame(maxWidth: .infinity)
            .frame(height: ConnSize.dockHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("ConnDock · 深色") {
    @Previewable @State var selection: ConnDock.Tab = .dashboard
    return ZStack(alignment: .bottom) {
        Color.connBg.ignoresSafeArea()
        ConnDock(selection: $selection)
    }
    .preferredColorScheme(.dark)
}

#Preview("ConnDock · 浅色") {
    @Previewable @State var selection: ConnDock.Tab = .hosts
    return ZStack(alignment: .bottom) {
        Color.connBg.ignoresSafeArea()
        ConnDock(selection: $selection)
    }
    .preferredColorScheme(.light)
}
