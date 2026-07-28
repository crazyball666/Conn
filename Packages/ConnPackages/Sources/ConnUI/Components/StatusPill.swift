import SwiftUI

/// 状态胶囊。
///
/// 设计规范 §2 约束：**色彩不是唯一指示**——每个语义自带形状符号
/// （●正常 ▲警告 ✕故障 ■停止 ✓成功 ▶动作），色盲用户与灰度打印同样可辨。
public struct StatusPill: View {
    /// 状态语义。每种对应一组固定的「符号 + 前景色 + 底色」。
    public enum Semantic: Sendable, CaseIterable {
        case good, warn, crit, off, info, accent

        /// 形状符号。与颜色构成双重编码。
        var symbol: String {
            switch self {
            case .good: "●"
            case .warn: "▲"
            case .crit: "✕"
            case .off: "■"
            case .info: "●"
            case .accent: "▶"
            }
        }

        var foreground: Color {
            switch self {
            case .good: .connGood
            case .warn: .connWarn
            case .crit: .connCrit
            case .off: .connMuted
            case .info: .connInfo
            case .accent: .connAccent
            }
        }

        var background: Color {
            switch self {
            case .good: .connGoodFill
            case .warn: .connWarnFill
            case .crit: .connCritFill
            case .off: .connOffFill
            case .info: .connInfoFill
            case .accent: .connAccentFill
            }
        }
    }

    private let text: String
    private let semantic: Semantic
    private let showsSymbol: Bool
    private let isBusy: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinAngle: Double = 0

    /// - Parameters:
    ///   - text: 胶囊文字，如「正常」「running」「exit 5」。
    ///   - semantic: 状态语义，决定符号与配色。
    ///   - showsSymbol: 是否显示前导形状符号。纯计数类徽标（如「12 台主机」）
    ///     不表达状态，可关闭。
    ///   - isBusy: 是否正在进行中。为真时把符号位换成转圈；`reduceMotion`
    ///     开启时退化为静态 `◌`——设计规范 §2 要求形状编码不能只靠颜色代替。
    public init(
        _ text: String,
        semantic: Semantic,
        showsSymbol: Bool = true,
        isBusy: Bool = false
    ) {
        self.text = text
        self.semantic = semantic
        self.showsSymbol = showsSymbol
        self.isBusy = isBusy
    }

    /// 忙碌时符号位该画什么。返回 nil 表示画转圈，否则用返回的静态符号。
    ///
    /// 抽成纯函数以便脱离 SwiftUI 单测。
    public static func busySymbol(reduceMotion: Bool) -> String? {
        reduceMotion ? "◌" : nil
    }

    public var body: some View {
        HStack(spacing: 5) {
            if showsSymbol {
                symbolView
            }
            Text(text)
        }
        .font(.connData(.caption))
        .fontWeight(.semibold)
        .connTabularNumbers()
        .foregroundStyle(semantic.foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .background(semantic.background, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private var symbolView: some View {
        if isBusy {
            if let fallback = Self.busySymbol(reduceMotion: reduceMotion) {
                Text(fallback)
            } else {
                spinner
            }
        } else {
            Text(semantic.symbol)
        }
    }

    /// 自绘转圈：一段 270° 圆弧匀速旋转。
    ///
    /// 不用系统 `ProgressView`——它的尺寸与配色不受令牌控制，在 18pt 高的胶囊里
    /// 偏大且颜色跟随 tint，与既有的符号编码不协调。
    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(semantic.foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(spinAngle))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            }
            .onDisappear { spinAngle = 0 }
    }
}

/// 胶囊样式的行内动作按钮。
///
/// 原型中「编辑」「▶ 执行」「保存」「去备份」等**可点动作**复用了状态胶囊的
/// 视觉（冲突台账 C48）。视觉与 `StatusPill` 完全一致，但补上按钮语义与
/// 44pt 热区——胶囊本身仅约 18pt 高，直接点会很难命中。
public struct PillButton: View {
    private let text: String
    private let semantic: StatusPill.Semantic
    private let showsSymbol: Bool
    private let action: () -> Void

    public init(
        _ text: String,
        semantic: StatusPill.Semantic = .accent,
        showsSymbol: Bool = false,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.semantic = semantic
        self.showsSymbol = showsSymbol
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            StatusPill(text, semantic: semantic, showsSymbol: showsSymbol)
                .connHitTarget(ConnSize.minTouchTarget)
        }
        .buttonStyle(ConnPressStyle())
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("StatusPill · 深色") {
    VStack(alignment: .leading, spacing: 12) {
        StatusPill("正常", semantic: .good)
        StatusPill("CPU 高", semantic: .warn)
        StatusPill("连接失败", semantic: .crit)
        StatusPill("stopped", semantic: .off)
        StatusPill("跟随中", semantic: .info)
        StatusPill("Pro", semantic: .accent, showsSymbol: false)
        StatusPill("重连中", semantic: .info, isBusy: true)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("StatusPill · 浅色") {
    VStack(alignment: .leading, spacing: 12) {
        StatusPill("正常", semantic: .good)
        StatusPill("CPU 高", semantic: .warn)
        StatusPill("连接失败", semantic: .crit)
        StatusPill("stopped", semantic: .off)
        StatusPill("跟随中", semantic: .info)
        StatusPill("Pro", semantic: .accent, showsSymbol: false)
        StatusPill("重连中", semantic: .info, isBusy: true)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
