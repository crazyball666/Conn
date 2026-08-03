import Foundation

/// ConnUI 本地化助手。ConnUI 刻意零依赖，故自持一份语言判定副本
/// （与 ConnKit.ConnLanguage 同键 `conn.language`，跨包共享当前语言）。
///
/// 从 ConnUI 资源 bundle 当前语言的 `.lproj` 子 bundle 查表——`String(localized:locale:)`
/// 的 locale 参数不选表，无法做 App 内语言覆盖，故走 `.lproj` 子 bundle。
/// Returns a localized value from the ConnUI resource bundle.
///
/// Public so UI packages built on top of ConnUI can localize accessibility
/// labels and other user-visible strings without duplicating bundle logic.
public func L(_ key: String) -> String {
    connUILocalizedBundle().localizedString(forKey: key, value: key, table: nil)
}

private func connUILocalizedBundle() -> Bundle {
    let identifier = connUICurrentIdentifier()
    if let path = Bundle.module.path(forResource: identifier, ofType: "lproj"),
       let sub = Bundle(path: path) {
        return sub
    }
    return .module
}

private func connUICurrentIdentifier() -> String {
    let supported = ["zh-Hans", "zh-Hant", "en", "ja", "ko"]
    let raw = UserDefaults.standard.string(forKey: "conn.language") ?? "system"
    if raw != "system", supported.contains(raw) {
        return raw
    }
    for language in Locale.preferredLanguages {
        let lower = language.lowercased()
        if lower.hasPrefix("zh") {
            let traditional = lower.contains("hant") || lower.contains("tw")
                || lower.contains("hk") || lower.contains("mo")
            return traditional ? "zh-Hant" : "zh-Hans"
        }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ko") { return "ko" }
        if lower.hasPrefix("en") { return "en" }
    }
    // 设备语言不在支持范围内时，统一使用 English，避免显示源语言中文。
    return "en"
}
