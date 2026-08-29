import Foundation

/// 编辑器按 Tab 时写入制表符，或按配置宽度写入空格。
public enum CodeIndentStyle: String, CaseIterable, Identifiable, Sendable {
    case spaces
    case tabs

    public var id: String { rawValue }
}

/// 代码编辑器的显示与输入偏好。
public struct CodeEditorConfiguration: Equatable, Sendable {
    public static let defaultFontSize: Double = 10

    public let theme: String
    public let fontSize: Double
    public let showsLineNumbers: Bool
    public let wrapsLines: Bool
    public let tabWidth: Int
    public let indentStyle: CodeIndentStyle

    public init(
        theme: String = CodeEditorCatalog.defaultThemeID,
        fontSize: Double = CodeEditorConfiguration.defaultFontSize,
        showsLineNumbers: Bool = true,
        wrapsLines: Bool = true,
        tabWidth: Int = 4,
        indentStyle: CodeIndentStyle = .spaces
    ) {
        self.theme = theme
        self.fontSize = fontSize
        self.showsLineNumbers = showsLineNumbers
        self.wrapsLines = wrapsLines
        self.tabWidth = max(1, tabWidth)
        self.indentStyle = indentStyle
    }

    /// 编辑器输入层用它把 Tab 键转换为用户选择的缩进字符。
    public func replacementText(for input: String) -> String {
        guard input == "\t", indentStyle == .spaces else { return input }
        return String(repeating: " ", count: tabWidth)
    }
}
