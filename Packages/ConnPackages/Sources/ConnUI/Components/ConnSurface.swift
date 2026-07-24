import SwiftUI

/// 卡片与列表行的表面处理。
///
/// 设计规范 §2 层次手法（按 NeoServer 实拍校准）：**不用外发光**。
/// 层级靠「色阶差」（卡片比背景亮约 8%）+ 卡片**顶边 1px 微光**
/// （`rgba(255,255,255,.05)` inset，模拟玻璃质感）。目标是「平面但有深度」。
public struct ConnSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let borderColor: Color?

    public func body(content: Content) -> some View {
        content
            .background {
                shape.fill(Color.connSurface)
                // 从上打光的体积渐变——顶部微提亮，让平面卡片有「被光照到」的立体感。
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.045 : 0.5), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            }
            .overlay(topEdgeHighlight)
            .overlay(shape.strokeBorder(borderColor ?? .connLine, lineWidth: 1))
            .compositingGroup()
            // 一层克制的落影：深色下也给一点漂浮感，但绝不喧宾夺主（保持「平面但有深度」）。
            .shadow(color: ambientShadow, radius: ambientRadius, y: ambientY)
    }

    private var shape: RoundedRectangle {
        .rect(cornerRadius: cornerRadius, style: .continuous)
    }

    private var ambientShadow: Color {
        colorScheme == .light ? .black.opacity(0.08) : .black.opacity(0.22)
    }

    private var ambientRadius: CGFloat { colorScheme == .light ? 5 : 9 }
    private var ambientY: CGFloat { colorScheme == .light ? 2 : 4 }

    /// 顶边 1px 微光——模拟玻璃边缘接住光。深色更明显。
    private var topEdgeHighlight: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [.white.opacity(colorScheme == .dark ? 0.09 : 0.65), .clear],
                startPoint: .top,
                endPoint: .center
            ),
            lineWidth: 1
        )
    }
}

public extension View {
    /// 应用 Conn 的卡片表面（色阶差 + 顶边微光 + 1px 描边）。
    ///
    /// - Parameters:
    ///   - cornerRadius: 圆角。卡片用 `ConnRadius.card`，列表行用 `ConnRadius.row`。
    ///   - borderColor: 描边色。传 nil 用默认 `connLine`；选中态传
    ///     `.connAccent.opacity(0.45)`，警告态 `.connWarn.opacity(0.35)`。
    func connSurface(
        cornerRadius: CGFloat = ConnRadius.card,
        borderColor: Color? = nil
    ) -> some View {
        modifier(ConnSurfaceModifier(cornerRadius: cornerRadius, borderColor: borderColor))
    }
}

/// 通用卡片容器。
public struct ConnCard<Content: View>: View {
    private let borderColor: Color?
    private let content: Content

    public init(borderColor: Color? = nil, @ViewBuilder content: () -> Content) {
        self.borderColor = borderColor
        self.content = content()
    }

    public var body: some View {
        content
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .connSurface(cornerRadius: ConnRadius.card, borderColor: borderColor)
    }
}

#Preview("ConnCard · 双主题") {
    VStack(spacing: 20) {
        ForEach([ColorScheme.dark, .light], id: \.self) { scheme in
            VStack(spacing: ConnSpacing.stackGap) {
                ConnCard {
                    Text("默认卡片")
                        .font(.connHeadline)
                        .foregroundStyle(.connInk)
                }
                ConnCard(borderColor: .connAccent.opacity(0.45)) {
                    Text("选中态描边")
                        .font(.connHeadline)
                        .foregroundStyle(.connInk)
                }
            }
            .padding(ConnSpacing.page)
            .background(Color.connBg)
            .environment(\.colorScheme, scheme)
        }
    }
}
