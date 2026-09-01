import CoreGraphics

/// 快捷键栏的视觉密度与触控尺寸。
///
/// 视觉键帽可以更小；方向盘保持紧凑栏原有尺寸，展开面板保留 44pt 触控高度。
public enum TerminalKeybarMetrics {
    public static let compactHeight: CGFloat = 46
    /// Compact row + category row + about three provider action rows on a compact iPhone.
    public static let expandedHeight: CGFloat = 284

    static let hitTargetHeight: CGFloat = 44
    static let capVisualHeight: CGFloat = 30
    static let compactCapWidth: CGFloat = 38
    /// 会话入口承载页面级导航与关闭操作，始终保留完整的 44pt 触控宽度。
    static let sessionActionsCapWidth: CGFloat = 44
    static let compactPadSide: CGFloat = 40
    /// 方向盘右侧留出独立的手指滑动余量，避免贴住屏幕边缘影响横向手势。
    static let directionPadTrailingInset: CGFloat = 8
    static let gridSpacing: CGFloat = 4
    static let commonColumnCount = 7
    static let providerColumnCount = 6
    static let providerIconSize: CGFloat = 12
    static let providerLabelSize: CGFloat = 10
    static let providerContentSpacing: CGFloat = 1
    static let providerContentHorizontalPadding: CGFloat = 4
    static let providerContentVerticalPadding: CGFloat = 2
}
