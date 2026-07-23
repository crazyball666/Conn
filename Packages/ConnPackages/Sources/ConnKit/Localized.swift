import Foundation

/// ConnKit 本地化助手：查本模块 catalog，语言取 `ConnLanguage`（当前语言的 .lproj 子 bundle）。
func L(_ key: String) -> String {
    ConnLanguage.localizedBundle(.module).localizedString(forKey: key, value: key, table: nil)
}
