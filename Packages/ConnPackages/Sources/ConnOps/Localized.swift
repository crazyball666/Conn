import ConnKit
import Foundation

/// ConnOps 本地化助手：查本模块 catalog，语言取 ConnKit.ConnLanguage。
func L(_ key: String) -> String {
    ConnLanguage.localizedBundle(.module).localizedString(forKey: key, value: key, table: nil)
}
