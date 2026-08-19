import SwiftUI

/// 底部 5 Tab 悬浮 Dock。
///
/// 设计规范 §5：距底 10pt、左右缩进 12pt、28pt 圆角、`connBar` 底 + 毛玻璃 + 细描边；
/// 选中项 accent 着色。原型受 HTML 限制未实现毛玻璃，此处按规范用
/// `.ultraThinMaterial` 落地（冲突台账 C31）。
public struct ConnDock: View {
    /// 四个根 Tab（信息架构 §5.0；「仪表盘 + 主机」已合并为「服务器」）。
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case servers, terminal, commands, me

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .servers: "主机"
            case .terminal: "终端"
            case .commands: "脚本"
            case .me: "设置"
            }
        }

        public var systemImage: String {
            switch self {
            case .servers: "server.rack"
            case .terminal: "terminal"
            case .commands: "command"
            case .me: "gearshape"
            }
        }
    }

    @Binding private var selection: Tab

    public init(selection: Binding<Tab>) {
        _selection = selection
    }

    @Namespace private var indicatorNamespace

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
        // 顶边接光，让 Dock 也像一块玻璃。
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
        // 选中指示器随切换平滑滑动（快而不弹,不喧宾）。
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: selection)
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
                    // 图标在被选中时轻弹一下——一个不打扰的微交互。
                    .symbolEffect(.bounce, value: selection == tab)
                Text(L(tab.title))
                    .font(.system(size: 11, weight: selection == tab ? .semibold : .regular))
            }
            .foregroundStyle(selection == tab ? Color.connAccent : .connMuted)
            .frame(maxWidth: .infinity)
            .frame(height: ConnSize.dockHeight)
            .background {
                // 选中态背后的辉光胶囊,借 matchedGeometry 从旧位置平滑滑过来。
                if selection == tab {
                    Capsule(style: .continuous)
                        .fill(Color.connAccentFill)
                        .matchedGeometryEffect(id: "dockIndicator", in: indicatorNamespace)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(tab.title))
        .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("ConnDock · 深色") {
    @Previewable @State var selection: ConnDock.Tab = .servers
    return ZStack(alignment: .bottom) {
        Color.connBg.ignoresSafeArea()
        ConnDock(selection: $selection)
    }
    .preferredColorScheme(.dark)
}

#Preview("ConnDock · 浅色") {
    @Previewable @State var selection: ConnDock.Tab = .terminal
    return ZStack(alignment: .bottom) {
        Color.connBg.ignoresSafeArea()
        ConnDock(selection: $selection)
    }
    .preferredColorScheme(.light)
}
