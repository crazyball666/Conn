import CoreGraphics

/// 间距、圆角、尺寸令牌。
///
/// 数值取自 `docs/prototypes/index.html`，按设计规范 §0 的换算口径：
/// **几何值按 1:1 读作 pt**（原型 `.card` radius 16px = 16pt，与规范 §4 精确吻合）。
public enum ConnSpacing {
    /// 4pt 网格的基本档位（设计规范 §4）。
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32

    /// 页面左右安全边距。iPad 用 `pageIPad`。
    public static let page: CGFloat = 16
    public static let pageIPad: CGFloat = 20

    /// 卡片内边距。原型为 13px，吸附到 4pt 网格取 12。
    public static let cardPadding: CGFloat = 12
    /// 列表行内边距（纵 × 横）。原型为 11×12px，吸附到 12×12。
    public static let rowPaddingV: CGFloat = 12
    public static let rowPaddingH: CGFloat = 12
    /// 卡片与行之间的默认间隙（原型 `.card` margin-bottom 10px、`.lrow` 8px）。
    public static let stackGap: CGFloat = 8
}

/// 圆角令牌。**一律使用连续曲率**（`.continuous`，squircle 观感）——
/// 圆角是本设计语言的显性特征（设计规范 §4）。
public enum ConnRadius {
    /// 卡片、指标环容器、ActionTile。
    public static let card: CGFloat = 16
    /// 列表行。
    public static let row: CGFloat = 14
    /// 按钮、图标容器、输入框、Banner、分段控件。
    public static let control: CGFloat = 12
    /// 终端键帽（原型 9px；低于规范 §4 的 10pt 下限，按 §0 裁决取原型值）。
    public static let key: CGFloat = 9
    /// 内联小标签 `.tagc`（原型 5px）。
    public static let tag: CGFloat = 5
    /// 弹层顶部。
    public static let sheet: CGFloat = 20
    /// TabBar 悬浮 Dock。
    public static let dock: CGFloat = 28
}

/// 组件尺寸令牌。
public enum ConnSize {
    /// 最小触控目标（HIG）。视觉尺寸可以更小，但**热区必须撑到此值**
    /// ——见 `View.connHitTarget()`（设计规范 §0 例外一）。
    public static let minTouchTarget: CGFloat = 44

    /// IconChip 功能图标底托边长。
    public static let iconChip: CGFloat = 34
    /// IconChip 内 SF Symbol 尺寸。
    public static let iconChipGlyph: CGFloat = 18
    /// IconChip 紧凑变体（首启价值卡、日志暂停按钮）。
    public static let iconChipCompact: CGFloat = 30

    /// 主按钮高度。
    public static let buttonHeight: CGFloat = 44
    /// 大号 CTA（Paywall、首启主按钮）。
    public static let buttonHeightLarge: CGFloat = 48

    /// TabBar 悬浮 Dock 高度。
    public static let dockHeight: CGFloat = 58
    /// Dock 距屏幕底部。
    public static let dockBottomInset: CGFloat = 10
    /// Dock 左右缩进。
    public static let dockHorizontalInset: CGFloat = 12
    /// 内容区需为 Dock 预留的底部空间（Dock 高度 + 上下间隙）。
    public static let dockContentInset: CGFloat = 76
    /// Dock 内图标尺寸（比通用 18pt 大）。
    public static let dockGlyph: CGFloat = 21

    /// 指标环外径与线宽（原型 58/7px，按 §0 裁决取原型值）。
    public static let gaugeDiameter: CGFloat = 58
    public static let gaugeLineWidth: CGFloat = 7

    /// HealthCard 迷你进度条高度。
    public static let miniBarHeight: CGFloat = 5
    /// 故障卡左侧警示条宽度。
    public static let critEdgeWidth: CGFloat = 3

    /// 状态点直径。
    public static let statusDot: CGFloat = 8

    /// ActionTile 高度（原型 66px）。
    public static let actionTile: CGFloat = 66

    /// 终端加速键条键高（原型 34px）。
    public static let keyHeight: CGFloat = 34
}

/// 指标阈值。超阈值时指标色统一切 warn / crit（设计规范 §5）。
public enum ConnThreshold {
    /// 低于此值视为「平静」，负载色标在这一段保持恒定绿。
    ///
    /// **只影响观感，不参与任何健康判定**——`HealthEvaluator` 只认 `warn` / `crit`。
    /// 之所以要留出这段平台期：50% 的 CPU 完全正常，若从 0 就开始往黄端爬，
    /// 用户每天都在看一片发黄的卡片，真正该警觉时反而失去对比。
    public static let calm: Double = 60
    /// 超过此值转为警告色。
    public static let warn: Double = 80
    /// 超过此值转为危险色。
    public static let crit: Double = 92
}
