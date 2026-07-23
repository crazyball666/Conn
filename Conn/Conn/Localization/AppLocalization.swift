import ConnKit
import Foundation
import Observation

/// App 层本地化助手：从主 bundle 当前语言的 `.lproj` 子 bundle 查表。
/// 语言取自 `ConnLanguage`（App 内切换 / 跟随系统，跨包经 UserDefaults 共享）。
func L(_ key: String) -> String {
    ConnLanguage.localizedBundle(.main).localizedString(forKey: key, value: key, table: nil)
}

/// 可选语言。`system` 跟随系统，其余为 5 种支持语言。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko

    var id: String { rawValue }

    /// 选择器显示名：各语言用其母语写法；「跟随系统」随当前语言本地化。
    var displayName: String {
        switch self {
        case .system: L("跟随系统")
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .en: "English"
        case .ja: "日本語"
        case .ko: "한국어"
        }
    }
}

/// 语言选择状态。切换即写 `UserDefaults`（供各包 L() 读取）；
/// 根视图以 `.id(language)` 观测它，切换时整树重建、全 App 立即改语言。
@Observable
@MainActor
final class LocalizationManager {
    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: ConnLanguage.storageKey)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: ConnLanguage.storageKey) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
    }
}
