import SwiftUI

/// 功能图标底托。
///
/// 设计规范 §5：34pt 方形、12pt 连续圆角、实色 tint 底（功能色 @16% 透明度）
/// + 同色系 SF Symbol、**无描边**。彩色底托是打破单色阴郁感的关键手法。
public struct IconChip: View {
    /// 语义配色。
    public enum Tint: Sendable {
        case neutral, good, warn, crit, accent, info

        var foreground: Color {
            switch self {
            case .neutral: .connMuted
            case .good: .connGood
            case .warn: .connWarn
            case .crit: .connCrit
            case .accent: .connAccent
            case .info: .connInfo
            }
        }

        var background: Color {
            switch self {
            case .neutral: .connTrack
            case .good: .connGoodFill
            case .warn: .connWarnFill
            case .crit: .connCritFill
            case .accent: .connAccentFill
            case .info: .connInfoFill
            }
        }
    }

    private let systemName: String
    private let tint: Tint
    private let size: CGFloat

    /// - Parameters:
    ///   - systemName: SF Symbol 名称。设计规范 §5：图标一律 SF Symbols，
    ///     **禁止 emoji 做图标**。
    ///   - tint: 语义配色。
    ///   - size: 底托边长，默认 34pt；紧凑场景用 `ConnSize.iconChipCompact`。
    public init(_ systemName: String, tint: Tint = .neutral, size: CGFloat = ConnSize.iconChip) {
        self.systemName = systemName
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.53, weight: .medium))
            .foregroundStyle(tint.foreground)
            .frame(width: size, height: size)
            .background(tint.background, in: .rect(cornerRadius: ConnRadius.control, style: .continuous))
    }
}

/// 可点击的 IconChip（导航栏「＋」、日志「暂停」等）。
public struct IconChipButton: View {
    private let systemName: String
    private let tint: IconChip.Tint
    private let size: CGFloat
    private let accessibilityLabel: String
    private let action: () -> Void

    public init(
        _ systemName: String,
        tint: IconChip.Tint = .neutral,
        size: CGFloat = ConnSize.iconChip,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.tint = tint
        self.size = size
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconChip(systemName, tint: tint, size: size)
                .connHitTarget()
        }
        .buttonStyle(ConnPressStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview("IconChip · 深色") {
    VStack(spacing: 16) {
        HStack(spacing: 12) {
            IconChip("server.rack")
            IconChip("checkmark.circle", tint: .good)
            IconChip("exclamationmark.triangle", tint: .warn)
            IconChip("xmark.octagon", tint: .crit)
            IconChip("sparkles", tint: .accent)
            IconChip("arrow.down.circle", tint: .info)
        }
        HStack(spacing: 12) {
            IconChip("folder", size: ConnSize.iconChipCompact)
            IconChipButton("plus", tint: .accent, accessibilityLabel: "添加主机") {}
        }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("IconChip · 浅色") {
    HStack(spacing: 12) {
        IconChip("server.rack")
        IconChip("checkmark.circle", tint: .good)
        IconChip("exclamationmark.triangle", tint: .warn)
        IconChip("xmark.octagon", tint: .crit)
        IconChip("sparkles", tint: .accent)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
