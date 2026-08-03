import Foundation

/// 全局当前语言（App 内切换 + 跟随系统）。
///
/// 各包与 App 的本地化助手统一读它选择查表 Locale——经 `UserDefaults` 共享，
/// **无需跨包依赖**（ConnUI 零依赖，自持一份同逻辑副本）。源语言为 zh-Hans。
public enum ConnLanguage {
    /// 语言选择的存储键；存 `"system"` 表示跟随系统。
    public static let storageKey = "conn.language"
    /// 支持集（源 zh-Hans + 4 目标）。
    public static let supported = ["zh-Hans", "zh-Hant", "en", "ja", "ko"]

    /// 当前用于本地化查表的 Locale。
    public static var currentLocale: Locale {
        Locale(identifier: currentIdentifier)
    }

    /// 取 `bundle` 下当前语言的 `.lproj` 子 bundle（找不到回退原 bundle）。
    ///
    /// 关键：`String(localized:locale:)` 的 `locale` 参数**不**用于选择本地化表，
    /// 无法实现 App 内语言覆盖。可靠做法是直接定位对应语言的 `.lproj` 子 bundle，
    /// 再走 `localizedString(forKey:)`。
    public static func localizedBundle(_ bundle: Bundle) -> Bundle {
        let identifier = currentIdentifier
        if let path = bundle.path(forResource: identifier, ofType: "lproj"),
           let sub = Bundle(path: path) {
            return sub
        }
        return bundle
    }

    /// 当前语言标识（已归一到支持集）。
    public static var currentIdentifier: String {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? "system"
        if raw != "system", supported.contains(raw) {
            return raw
        }
        return systemPreferred()
    }

    /// 将系统首选语言解析为 App 支持的语言。
    ///
    /// 设备语言不在支持范围内时，使用 English 作为稳定的产品级回退语言，
    /// 避免用户在不支持的语言环境下意外看到源语言中文。
    static func systemPreferred(_ preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        for language in preferredLanguages {
            if let match = match(language) { return match }
        }
        return "en"
    }

    /// 把系统语言码归一到支持集（zh-Hant-TW→zh-Hant，ja-JP→ja…）。
    static func match(_ identifier: String) -> String? {
        let lower = identifier.lowercased()
        if lower.hasPrefix("zh") {
            let traditional = lower.contains("hant") || lower.contains("tw")
                || lower.contains("hk") || lower.contains("mo")
            return traditional ? "zh-Hant" : "zh-Hans"
        }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ko") { return "ko" }
        if lower.hasPrefix("en") { return "en" }
        return nil
    }
}
