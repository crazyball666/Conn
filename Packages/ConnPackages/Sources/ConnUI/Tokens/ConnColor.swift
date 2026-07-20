import SwiftUI

/// Conn 设计系统的色彩令牌。
///
/// 真值来源为 `docs/prototypes/index.html` 的 CSS 变量（设计规范 §0 裁决规则：
/// 原型 CSS 实际值 > 规范文字表述）。色板由 `Tooling/generate_color_assets.py`
/// 从单一令牌表生成，**不要手改 Media.xcassets**——改令牌请改脚本后重跑。
///
/// 铁律（设计规范 §1）：
/// - **状态先于装饰**：色彩优先编码健康状态；`connAccent` 是品牌/交互色，
///   **禁止**用来表示"健康正常"。
/// - 色彩不是唯一指示：状态点必须伴随文字或形状。
public extension ShapeStyle where Self == Color {
    // MARK: - 基础层次

    /// 页面底色（深空蓝黑，非纯黑，避免 OLED 拖影）。
    static var connBg: Color { .token("connBg") }
    /// 卡片与列表行底色。比 `connBg` 亮约 8%，层级靠色阶差而非阴影。
    static var connSurface: Color { .token("connSurface") }
    /// 弹层与浮层底色。
    static var connElevated: Color { .token("connElevated") }
    /// 分隔线与描边（1px）。
    static var connLine: Color { .token("connLine") }

    // MARK: - 文本

    /// 主文本（对比度 ≥ 12:1）。
    static var connInk: Color { .token("connInk") }
    /// 次要文本（对比度 ≥ 4.6:1，禁止再淡）。
    static var connMuted: Color { .token("connMuted") }
    /// 三级文本与图标（chevron、未激活状态点），弱于 `connMuted`。
    static var connDim: Color { .token("connDim") }

    // MARK: - 品牌与交互

    /// 品牌/交互色（电光长春花蓝）：链接、选中态、光标、图标。
    /// **禁止**用来表示"健康正常"——那是 `connGood` 的职责。
    static var connAccent: Color { .token("connAccent") }
    /// 填充按钮底色（配白字）。主按钮用 `connAccent → connAccentDeep` 纵向微渐变。
    static var connAccentDeep: Color { .token("connAccentDeep") }

    // MARK: - 状态

    /// 状态·正常。**仅**用于状态点、趋势等小元素，绝不大面积填充。
    static var connGood: Color { .token("connGood") }
    /// 状态·警告。
    static var connWarn: Color { .token("connWarn") }
    /// 状态·故障与危险操作。出现即为最高优先级。
    static var connCrit: Color { .token("connCrit") }
    /// 状态·信息与传输中（冰青，航电仪表辉光）。
    static var connInfo: Color { .token("connInfo") }
    /// 磁盘指标专属色（琥珀）。
    static var connDisk: Color { .token("connDisk") }

    // MARK: - 状态半透明填充

    /// StatusPill / IconChip 的正常态底色。
    static var connGoodFill: Color { .token("connGoodFill") }
    /// 警告态底色。
    static var connWarnFill: Color { .token("connWarnFill") }
    /// 故障态底色（LogLine ERROR 行亦用此色）。
    static var connCritFill: Color { .token("connCritFill") }
    /// 信息态底色。
    static var connInfoFill: Color { .token("connInfoFill") }
    /// 品牌态底色（Pro 徽章、选中态）。
    static var connAccentFill: Color { .token("connAccentFill") }
    /// 已停止态底色。
    static var connOffFill: Color { .token("connOffFill") }

    // MARK: - 结构性

    /// TabBar 悬浮 Dock、终端加速键条、编辑器符号条的底色。
    static var connBar: Color { .token("connBar") }
    /// 键帽底色。
    static var connKey: Color { .token("connKey") }
    /// 键帽描边（比 `connLine` 对比更强，保证键位可辨）。
    static var connKeyline: Color { .token("connKeyline") }
    /// 进度条槽、指标环底圈、IconChip 默认底托。
    static var connTrack: Color { .token("connTrack") }

    // MARK: - 终端与日志（两主题恒定，因终端画布恒为深色）

    /// 终端画布底色。**浅色模式下终端仍为深色**，行业惯例。
    static var connTermBg: Color { .token("connTermBg") }
    /// 终端正文。
    static var connTermFg: Color { .token("connTermFg") }
    /// 终端与日志的时间戳、分隔符。
    static var connTermDim: Color { .token("connTermDim") }
    /// 日志正文。
    static var connLogFg: Color { .token("connLogFg") }
    /// 日志 ERROR 行文字。
    static var connLogErrFg: Color { .token("connLogErrFg") }
    /// 日志 WARN 行文字。
    static var connLogWarnFg: Color { .token("connLogWarnFg") }
    /// 代码编辑器行号。
    static var connCodeLineNo: Color { .token("connCodeLineNo") }
    /// 代码注释。
    static var connCodeComment: Color { .token("connCodeComment") }
}

public extension Color {
    /// 从 ConnUI 包内的色板加载令牌。
    ///
    /// 令牌名是设计系统的编译期常量，由 `Tooling/generate_color_assets.py`
    /// 与本文件同源生成；令牌完整性由 `ConnColorTokenTests` 在测试中校验，
    /// 不在运行时重复检查。
    static func token(_ name: String) -> Color {
        Color(name, bundle: .module)
    }
}
