import SwiftUI

/// 字体令牌。
///
/// 换算口径（设计规范 §0）：原型字号按 ×1.219 换算后**吸附到 iOS 类型比例**，
/// 因此这里一律用系统文本样式而非硬编码字号——既符合规范 §3「禁止自造字号」，
/// 也自动获得 Dynamic Type 支持。
///
/// 铁律（设计规范 §1）：**一切数字、地址、路径、命令用等宽 + `tabular-nums`**，
/// 杜绝数值跳动。
public extension Font {
    /// 页面大标题。
    static var connTitle: Font { .largeTitle.weight(.bold) }
    /// 二级页标题、区块标题。
    static var connSectionTitle: Font { .title3.weight(.semibold) }
    /// 卡片标题、列表主文本。
    static var connHeadline: Font { .headline }
    /// 正文。
    static var connBody: Font { .body }
    /// 次要信息。
    static var connSubheadline: Font { .subheadline }
    /// 说明、标签、键帽。
    static var connFootnote: Font { .footnote }
    /// 徽标、眉标（配合 `.connEyebrowTracking` 字距）。
    static var connCaption: Font { .caption2.weight(.semibold) }

    /// 数据等宽字体：地址、路径、命令、指标数值。
    ///
    /// - Parameter style: 跟随的文本样式，默认 `.footnote`（原型中 mono 多为小字号）。
    static func connData(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .monospaced)
    }

    /// 大数字仪表专用（指标环中心数值）。
    ///
    /// 用 `.rounded` 而非 `.monospaced`：圆体在大字号下更符合航电仪表观感，
    /// 数字等宽由 `.monospacedDigit()` 修饰符保证（见 `View.connTabularNumbers()`）。
    static func connGaugeValue(_ size: CGFloat = 18) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
}

public extension View {
    /// 开启表格数字（等宽数字位）。
    ///
    /// 一切会变化的数值都必须加，否则百分比、速率、计数刷新时字符宽度变化
    /// 会导致布局跳动——这是设计规范 §1 铁律二。
    func connTabularNumbers() -> some View {
        monospacedDigit()
    }

    /// 眉标字距（全大写小标题，如「CONN PRO」「常用片段」）。
    func connEyebrowTracking() -> some View {
        tracking(0.6)
    }

    /// 大标题光学字距（设计规范 §15：字号越大，字母间距视觉上越松，需收紧）。
    ///
    /// 仅用于 `connTitle`/`connSectionTitle` 级别的展示型标题——拉丁文与数字
    /// （如「db-master」「94%」）在大字号下收紧后更紧致、更有分量。正文不收。
    func connDisplayTracking() -> some View {
        tracking(-0.5)
    }

    /// 把点击热区撑到 HIG 要求的 44×44pt，**不改变视觉尺寸**。
    ///
    /// 设计规范 §0 例外一：原型中存在视觉尺寸小于 44pt 的可点元素
    /// （键帽 34pt、被当按钮用的状态胶囊 18pt）。视觉照原型，热区靠此修饰符
    /// 补足，两者不冲突。
    func connHitTarget(_ minimum: CGFloat = ConnSize.minTouchTarget) -> some View {
        frame(minWidth: minimum, minHeight: minimum)
            .contentShape(Rectangle())
    }
}
