import SwiftUI

/// 列表行的强调描边语义。
public enum ConnRowEmphasis: Sendable {
    case none, selected, warning, danger

    var borderColor: Color? {
        switch self {
        case .none: nil
        case .selected: Color.connAccent.opacity(0.45)
        case .warning: Color.connWarn.opacity(0.35)
        case .danger: Color.connCrit.opacity(0.35)
        }
    }
}

/// 列表行标题后的内联小标签，如 `prod`、`{{port}}`、`Secure Enclave`。
public struct ConnRowTag: Identifiable, Sendable {
    public enum Kind: Sendable {
        case neutral, info, danger, accent, warning

        var color: Color {
            switch self {
            case .neutral: .connMuted
            case .info: .connInfo
            case .danger: .connCrit
            case .accent: .connAccent
            case .warning: .connWarn
            }
        }
    }

    public let id: UUID
    public let text: String
    public let kind: Kind

    public init(_ text: String, kind: Kind = .neutral) {
        id = UUID()
        self.text = text
        self.kind = kind
    }

    var color: Color { kind.color }
}

/// 通用列表行。
///
/// 原型里 `.lrow` 一个类承担了六种角色（主机 / 容器 / 文件 / 片段 / 设置 / 密钥），
/// 覆盖 21 屏中的绝大部分列表，因此这里做成可组合的通用件：
/// 前导（IconChip 或状态点）+ 标题/副标题 + 尾部（StatusPill 或 chevron）。
public struct ConnListRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let tags: [ConnRowTag]
    private let emphasis: ConnRowEmphasis
    private let isDimmed: Bool
    private let leading: Leading
    private let trailing: Trailing
    private let action: (() -> Void)?

    public init(
        title: String,
        subtitle: String? = nil,
        tags: [ConnRowTag] = [],
        emphasis: ConnRowEmphasis = .none,
        isDimmed: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tags = tags
        self.emphasis = emphasis
        self.isDimmed = isDimmed
        self.leading = leading()
        self.trailing = trailing()
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(ConnPressStyle())
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                if let subtitle {
                    Text(subtitle)
                        .font(.connData(.caption))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: ConnSpacing.xxs)
            trailing
        }
        .padding(.vertical, ConnSpacing.rowPaddingV)
        .padding(.horizontal, ConnSpacing.rowPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .connSurface(cornerRadius: ConnRadius.row, borderColor: emphasis.borderColor)
        // 停止/失效态整行降透明度（原型 .66）
        .opacity(isDimmed ? 0.66 : 1)
    }

    private var titleLine: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.connBody)
                .fontWeight(.semibold)
                .foregroundStyle(.connInk)
                .lineLimit(1)
            ForEach(tags) { tag in
                Text(tag.text)
                    .font(.connData(.caption2))
                    .foregroundStyle(tag.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: ConnRadius.tag, style: .continuous)
                            .strokeBorder(tag.color.opacity(0.4), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - 便利构造

public extension ConnListRow where Trailing == ConnChevron {
    /// 尾部为 chevron 的可点击行（最常见形态）。
    init(
        title: String,
        subtitle: String? = nil,
        tags: [ConnRowTag] = [],
        emphasis: ConnRowEmphasis = .none,
        isDimmed: Bool = false,
        @ViewBuilder leading: () -> Leading,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            tags: tags,
            emphasis: emphasis,
            isDimmed: isDimmed,
            leading: leading,
            trailing: { ConnChevron() },
            action: action
        )
    }
}

/// 列表行尾部的导航指示箭头。
public struct ConnChevron: View {
    public init() {}

    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.connDim)
    }
}

/// 状态圆点。设计规范 §2：色彩不是唯一指示，故此件仅用于**已有文字说明**的场景。
public struct ConnStatusDot: View {
    private let status: ConnHealthStatus
    private let size: CGFloat

    public init(_ status: ConnHealthStatus, size: CGFloat = ConnSize.statusDot) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .ok: .connGood
        case .warn: .connWarn
        case .crit, .offline: .connCrit
        case .unknown: .connDim
        }
    }
}

#Preview("ConnListRow · 深色") {
    VStack(spacing: ConnSpacing.stackGap) {
        ConnListRow(
            title: "web-01",
            subtitle: "root@10.0.0.1",
            tags: [.init("prod", kind: .danger), .init("web")],
            leading: { ConnStatusDot(.ok) },
            action: {}
        )
        ConnListRow(
            title: "nginx-proxy",
            subtitle: "nginx:1.25-alpine",
            leading: { IconChip("shippingbox", tint: .good) },
            trailing: { StatusPill("running", semantic: .good) }
        )
        ConnListRow(
            title: "redis-cache",
            subtitle: "redis:7",
            isDimmed: true,
            leading: { IconChip("shippingbox") },
            trailing: { StatusPill("stopped", semantic: .off) }
        )
        ConnListRow(
            title: "id_ed25519_work",
            subtitle: "SHA256:abc123…",
            tags: [.init("Secure Enclave", kind: .accent)],
            emphasis: .selected,
            leading: { IconChip("key.fill", tint: .accent) },
            action: {}
        )
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("ConnListRow · 浅色") {
    VStack(spacing: ConnSpacing.stackGap) {
        ConnListRow(
            title: "web-01",
            subtitle: "root@10.0.0.1",
            tags: [.init("prod", kind: .danger)],
            leading: { ConnStatusDot(.ok) },
            action: {}
        )
        ConnListRow(
            title: "nginx-proxy",
            subtitle: "nginx:1.25-alpine",
            leading: { IconChip("shippingbox", tint: .good) },
            trailing: { StatusPill("running", semantic: .good) }
        )
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
