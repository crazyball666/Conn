import SwiftUI

/// 主按钮与次按钮。
///
/// 设计规范 §5：主按钮 `accent → accentDeep` 纵向微渐变 + 极轻投影
/// （accent @22%，radius ≤10）；ghost 为透明底 + 1px 描边。
public struct ConnButton: View {
    /// 视觉层级。
    public enum Kind: Sendable {
        /// 主行动号召。一屏最多一个。
        case primary
        /// 次要动作，透明底 + 描边。
        case ghost
        /// 破坏性动作。文案必须写明对象（「停止 nginx-proxy」而非「确定」）。
        case destructive
    }

    private let title: String
    private let kind: Kind
    private let height: CGFloat
    private let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ title: String,
        kind: Kind = .primary,
        height: CGFloat = ConnSize.buttonHeight,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.height = height
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.connBody)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .foregroundStyle(foreground)
                .background(background)
                .overlay(border)
                .clipShape(.rect(cornerRadius: ConnRadius.control, style: .continuous))
                .shadow(
                    color: isEnabled && kind == .primary ? Color.connAccentDeep.opacity(0.22) : .clear,
                    radius: isEnabled && kind == .primary ? 10 : 0,
                    y: isEnabled && kind == .primary ? 2 : 0
                )
        }
        .buttonStyle(ConnPressStyle())
    }

    private var foreground: Color {
        guard isEnabled else { return .connMuted }
        switch kind {
        case .primary: return .white
        case .ghost: return .connInk
        case .destructive: return .connCrit
        }
    }

    @ViewBuilder
    private var background: some View {
        if !isEnabled {
            Color.connMuted.opacity(0.16)
        } else {
            switch kind {
            case .primary:
                LinearGradient(
                    colors: [.connAccent, .connAccentDeep],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .ghost, .destructive:
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var border: some View {
        switch kind {
        case .primary:
            EmptyView()
        case .ghost:
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connLine, lineWidth: 1)
        case .destructive:
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(Color.connCrit.opacity(0.35), lineWidth: 1)
        }
    }
}

/// 提示横幅。
///
/// 设计规范 §5：12pt 圆角、语义色 @10% 底 + @35% 描边。
/// 用于免费版限额提示、承诺声明、安全警示等。
public struct ConnBanner: View {
    public enum Kind: Sendable {
        case info, warn, crit

        var tint: Color {
            switch self {
            case .info: .connAccent
            case .warn: .connWarn
            case .crit: .connCrit
            }
        }
    }

    private let text: String
    private let systemImage: String?
    private let kind: Kind

    public init(_ text: String, systemImage: String? = nil, kind: Kind = .info) {
        self.text = text
        self.systemImage = systemImage
        self.kind = kind
    }

    public var body: some View {
        HStack(spacing: ConnSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
            Spacer(minLength: 0)
        }
        .font(.connFootnote)
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, ConnSpacing.xs)
        .background(kind.tint.opacity(0.10), in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.35), lineWidth: 1)
        )
    }
}

#Preview("按钮与横幅 · 深色") {
    VStack(spacing: ConnSpacing.sm) {
        ConnButton("添加我的服务器") {}
        ConnButton("停止 nginx-proxy", kind: .destructive) {}
        ConnBanner("免费版已用 3/3 台主机，升级专业版解锁无限主机", systemImage: "info.circle")
        ConnBanner("恢复码尚未备份", systemImage: "exclamationmark.triangle", kind: .warn)
        ConnBanner("主机指纹已变更，连接已阻断", systemImage: "xmark.shield", kind: .crit)
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("按钮与横幅 · 浅色") {
    VStack(spacing: ConnSpacing.sm) {
        ConnButton("添加我的服务器") {}
        ConnBanner("免费版已用 3/3 台主机", systemImage: "info.circle")
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
