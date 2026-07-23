import ConnKit
import Foundation

/// ConnRunner 本地化助手：查本模块 catalog，语言取 ConnKit.ConnLanguage。
func L(_ key: String) -> String {
    ConnLanguage.localizedBundle(.module).localizedString(forKey: key, value: key, table: nil)
}

/// 一个中文源串在全部支持语言下的所有译文（含源串本身），用于识别「未改动的内置片段」。
func allLanguageVariants(_ key: String) -> Set<String> {
    var variants: Set<String> = [key]
    for language in ["zh-Hant", "en", "ja", "ko"] {
        if let path = Bundle.module.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            variants.insert(bundle.localizedString(forKey: key, value: key, table: nil))
        }
    }
    return variants
}
