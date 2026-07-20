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
            .background(Color.connSurface, in: shape)
            .overlay(topEdgeHighlight)
            .overlay(shape.strokeBorder(borderColor ?? .connLine, lineWidth: 1))
            .compositingGroup()
            .shadow(
                color: colorScheme == .light ? Color.black.opacity(0.07) : .clear,
                radius: colorScheme == .light ? 4 : 0,
                y: colorScheme == .light ? 1 : 0
            )
    }

    private var shape: RoundedRectangle {
        .rect(cornerRadius: cornerRadius, style: .continuous)
    }

    /// 顶边 1px 微光。仅深色下出现——浅色档原型用的是投影而非 inset 高光。
    @ViewBuilder
    private var topEdgeHighlight: some View {
        if colorScheme == .dark {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.05), .clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 1
                )
        }
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
