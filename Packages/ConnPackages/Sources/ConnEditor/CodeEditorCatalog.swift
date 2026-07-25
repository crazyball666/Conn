import Foundation

/// 代码主题（供设置页选择）。`id` 为 highlight.js 主题标识。
public struct CodeTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let isDark: Bool

    public init(id: String, displayName: String, isDark: Bool) {
        self.id = id
        self.displayName = displayName
        self.isDark = isDark
    }
}

/// 主题目录 + 由文件名推断 highlight.js 语言标识。跨平台纯逻辑（无 UIKit），host 可测。
public enum CodeEditorCatalog {
    /// 精选主题（浅色在前、深色在后），取自 highlight.js 内置主题子集。
    public static let themes: [CodeTheme] = [
        CodeTheme(id: "xcode", displayName: "Xcode", isDark: false),
        CodeTheme(id: "github", displayName: "GitHub", isDark: false),
        CodeTheme(id: "atom-one-light", displayName: "Atom One Light", isDark: false),
        CodeTheme(id: "solarized-light", displayName: "Solarized Light", isDark: false),
        CodeTheme(id: "vs", displayName: "Visual Studio", isDark: false),
        CodeTheme(id: "atom-one-dark", displayName: "Atom One Dark", isDark: true),
        CodeTheme(id: "dracula", displayName: "Dracula", isDark: true),
        CodeTheme(id: "monokai", displayName: "Monokai", isDark: true),
        CodeTheme(id: "nord", displayName: "Nord", isDark: true),
        CodeTheme(id: "solarized-dark", displayName: "Solarized Dark", isDark: true),
        CodeTheme(id: "tomorrow-night-bright", displayName: "Tomorrow Night", isDark: true),
        CodeTheme(id: "vs2015", displayName: "VS2015", isDark: true)
    ]

    public static let defaultThemeID = "xcode"

    public static func theme(id: String) -> CodeTheme {
        themes.first { $0.id == id } ?? themes[0]
    }

    /// highlight.js 语言标识（由文件名 / 扩展名推断）。未知返回 nil（纯文本）。
    public static func language(forFileName name: String) -> String? {
        let lower = ((name as NSString).lastPathComponent).lowercased()
        if lower == "dockerfile" || lower.hasPrefix("dockerfile.") { return "dockerfile" }
        if lower == "makefile" || lower == "gnumakefile" { return "makefile" }
        if lower.hasPrefix("nginx") { return "nginx" }
        if lower == ".env" || lower.hasPrefix(".env.") { return "bash" }
        if lower == ".bashrc" || lower == ".zshrc" || lower == ".profile" { return "bash" }
        return byExtension[(lower as NSString).pathExtension]
    }

    private static let byExtension: [String: String] = {
        var map: [String: String] = [:]
        func put(_ lang: String, _ extensions: [String]) { for ext in extensions { map[ext] = lang } }
        put("bash", ["sh", "bash", "zsh", "fish", "env"])
        put("python", ["py", "pyw"])
        put("javascript", ["js", "mjs", "cjs", "jsx"])
        put("typescript", ["ts", "tsx"])
        put("json", ["json"])
        put("yaml", ["yml", "yaml"])
        put("ini", ["ini", "conf", "cnf", "cfg", "toml", "properties"])
        put("nginx", ["nginx"])
        put("xml", ["xml", "plist", "svg"])
        put("sql", ["sql"])
        put("markdown", ["md", "markdown"])
        put("go", ["go"])
        put("ruby", ["rb"])
        put("php", ["php"])
        put("c", ["c", "h"])
        put("cpp", ["cpp", "cc", "cxx", "hpp"])
        put("swift", ["swift"])
        put("rust", ["rs"])
        put("java", ["java"])
        put("kotlin", ["kt", "kts"])
        put("dockerfile", ["dockerfile"])
        put("perl", ["pl", "pm"])
        put("lua", ["lua"])
        put("html", ["html", "htm"])
        put("css", ["css", "scss", "less"])
        return map
    }()
}
