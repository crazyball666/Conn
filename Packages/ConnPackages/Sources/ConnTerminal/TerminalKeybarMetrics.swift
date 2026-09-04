import CoreGraphics

/// 快捷键栏的视觉密度与触控尺寸。
///
    /// 紧凑栏与系统键盘保持一致的 44pt 触控高度。
public enum TerminalKeybarMetrics {
    public static let compactHeight: CGFloat = 46
    /// Compact row + category row + about three provider action rows on a compact iPhone.
    public static let expandedHeight: CGFloat = 284

    static let hitTargetHeight: CGFloat = 44
    /// Compact row content keeps a symmetric breathing room on both screen edges.
    static let compactHorizontalInset: CGFloat = 8
    static let capVisualHeight: CGFloat = 28
    static let compactCapWidth: CGFloat = 44
    static let compactActionWidth: CGFloat = 64
    static let compactPadSide: CGFloat = 44
    static let gridSpacing: CGFloat = 4
    static let commonColumnCount = 7
    static let providerColumnCount = 6
    static let providerLabelSize: CGFloat = 10
    static let providerContentSpacing: CGFloat = 1
    static let providerContentHorizontalPadding: CGFloat = 4
    static let providerContentVerticalPadding: CGFloat = 2
}
