import SwiftUI

/// 品牌强调色的运行时覆盖点。
///
/// 设计令牌 `connAccent` / `connAccentFill` / `connAccentDeep` 默认取自资源目录
/// （品牌靛蓝）。设置页可调 `apply(_:)` 换成用户选择的主题色，`reset()` 恢复默认。
/// 因 `connAccent` 被全 App 40+ 处引用，改此单点即整体换肤——配合根视图 `.id`
/// 在切换时重建视图树，令所有引用重新读取新色。
public enum ConnTheme {
    public static var accent: Color = .token("connAccent")
    public static var accentFill: Color = .token("connAccentFill")
    public static var accentDeep: Color = .token("connAccentDeep")

    /// 恢复设计令牌默认（品牌靛蓝）。
    public static func reset() {
        accent = .token("connAccent")
        accentFill = .token("connAccentFill")
        accentDeep = .token("connAccentDeep")
    }

    /// 换成用户主题色；填充态由该色 15% 透明派生、加深态取该色。
    public static func apply(_ color: Color) {
        accent = color
        accentFill = color.opacity(0.15)
        accentDeep = color
    }
}
