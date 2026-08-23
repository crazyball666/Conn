import ConnEditor
import ConnTerminal
import ConnUI
import Foundation
import Observation
import SwiftUI

/// 外观模式：跟随系统 / 浅色 / 深色。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: L("跟随系统")
        case .light: L("浅色")
        case .dark: L("深色")
        }
    }

    /// nil = 跟随系统。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 主题色预设。`brand` 使用设计令牌中的品牌暖珊瑚色。
enum AppAccent: String, CaseIterable, Identifiable {
    case brand, blue, teal, green, orange, pink, purple
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .brand: .token("connAccent")
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .purple: .purple
        }
    }

    var label: String {
        switch self {
        case .brand: L("默认")
        case .blue: L("蓝")
        case .teal: L("青")
        case .green: L("绿")
        case .orange: L("橙")
        case .pink: L("粉")
        case .purple: L("紫")
        }
    }
}

/// 主页数据刷新间隔（仪表盘轮询周期）。
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case fast = 10
    case normal = 30
    case slow = 60
    var id: Int { rawValue }
    var label: String { String(format: L("%ds"), rawValue) }
    var duration: Duration { .seconds(rawValue) }
}

/// App Store 公开法律页面。必须保持为可公开访问的 HTTPS 地址。
enum AppLegalLinks {
    static let privacyPolicyURL: URL? = {
        guard let url = URL(string: "https://crazyball.cc/ConnTerm/privacy/"),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return url
    }()
}

/// App 偏好设置（UserDefaults 落盘）。外观即时应用、主题色改单点即整体换肤。
@Observable
@MainActor
final class SettingsStore {
    private let defaults: UserDefaults

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var accent: AppAccent {
        didSet {
            defaults.set(accent.rawValue, forKey: Key.accent)
            applyAccent()
        }
    }

    var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Key.refresh) }
    }

    /// Docker 容器/镜像数据的刷新间隔（详情页 Docker 段自动刷新）。
    var dockerRefreshInterval: RefreshInterval {
        didSet { defaults.set(dockerRefreshInterval.rawValue, forKey: Key.dockerRefresh) }
    }

    /// 代码编辑器主题（highlight.js 主题 id）。
    var codeTheme: String {
        didSet { defaults.set(codeTheme, forKey: Key.codeTheme) }
    }

    var codeFontSize: Double {
        didSet { defaults.set(codeFontSize, forKey: Key.codeFontSize) }
    }

    var codeShowsLineNumbers: Bool {
        didSet { defaults.set(codeShowsLineNumbers, forKey: Key.codeShowsLineNumbers) }
    }

    var codeLineWrapping: Bool {
        didSet { defaults.set(codeLineWrapping, forKey: Key.codeLineWrapping) }
    }

    var codeTabWidth: Int {
        didSet { defaults.set(codeTabWidth, forKey: Key.codeTabWidth) }
    }

    var codeIndentStyle: CodeIndentStyle {
        didSet { defaults.set(codeIndentStyle.rawValue, forKey: Key.codeIndentStyle) }
    }

    var terminalThemeID: String {
        didSet { defaults.set(terminalThemeID, forKey: Key.terminalTheme) }
    }

    var terminalFontSize: Double {
        didSet { defaults.set(terminalFontSize, forKey: Key.terminalFontSize) }
    }

    var terminalScrollback: Int {
        didSet { defaults.set(terminalScrollback, forKey: Key.terminalScrollback) }
    }

    var terminalCursorShape: TerminalCursorShape {
        didSet { defaults.set(terminalCursorShape.rawValue, forKey: Key.terminalCursorShape) }
    }

    var terminalCursorBlinking: Bool {
        didSet { defaults.set(terminalCursorBlinking, forKey: Key.terminalCursorBlinking) }
    }

    var terminalKeybarEnabled: Bool {
        didSet { defaults.set(terminalKeybarEnabled, forKey: Key.terminalKeybarEnabled) }
    }

    /// v1 内置命令库是否曾导入；仅供版本化目录首次迁移使用。
    /// 新目录进度与 suppression 已迁入 SQLite，不再以此布尔值作为导入 gate。
    var builtinSnippetsImported: Bool {
        didSet { defaults.set(builtinSnippetsImported, forKey: Key.builtinSnippetsImported) }
    }

    /// 供 `ConnApp` 在构造 `SettingsStore` 之前直接查 UserDefaults 用。
    static let builtinSnippetsImportedKey = Key.builtinSnippetsImported

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 只在没有持久化值时使用默认值；已有用户偏好保持不变。
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .dark
        accent = AppAccent(rawValue: defaults.string(forKey: Key.accent) ?? "") ?? .purple
        let storedInterval = defaults.object(forKey: Key.refresh) as? Int ?? RefreshInterval.normal.rawValue
        refreshInterval = RefreshInterval(rawValue: storedInterval) ?? .normal
        let storedDocker = defaults.object(forKey: Key.dockerRefresh) as? Int ?? RefreshInterval.normal.rawValue
        dockerRefreshInterval = RefreshInterval(rawValue: storedDocker) ?? .normal
        codeTheme = CodeEditorCatalog.theme(
            id: defaults.string(forKey: Key.codeTheme) ?? CodeEditorCatalog.defaultThemeID
        ).id
        let storedCodeFontSize = defaults.object(forKey: Key.codeFontSize) == nil
            ? 13
            : defaults.double(forKey: Key.codeFontSize)
        codeFontSize = (10 ... 24).contains(storedCodeFontSize) ? storedCodeFontSize : 13
        codeShowsLineNumbers = defaults.object(forKey: Key.codeShowsLineNumbers) == nil
            ? true
            : defaults.bool(forKey: Key.codeShowsLineNumbers)
        codeLineWrapping = defaults.object(forKey: Key.codeLineWrapping) == nil
            ? true
            : defaults.bool(forKey: Key.codeLineWrapping)
        let storedCodeTabWidth = defaults.object(forKey: Key.codeTabWidth) == nil
            ? 4
            : defaults.integer(forKey: Key.codeTabWidth)
        codeTabWidth = [2, 4, 8].contains(storedCodeTabWidth) ? storedCodeTabWidth : 4
        codeIndentStyle = CodeIndentStyle(
            rawValue: defaults.string(forKey: Key.codeIndentStyle) ?? ""
        ) ?? .spaces
        terminalThemeID = TerminalTheme.theme(
            id: defaults.string(forKey: Key.terminalTheme) ?? TerminalTheme.conn.id
        ).id
        terminalFontSize = defaults.object(forKey: Key.terminalFontSize) == nil
            ? TerminalConfiguration.defaultFontSize
            : defaults.double(forKey: Key.terminalFontSize)
        terminalScrollback = defaults.object(forKey: Key.terminalScrollback) == nil
            ? 500
            : defaults.integer(forKey: Key.terminalScrollback)
        terminalCursorShape = TerminalCursorShape(
            rawValue: defaults.string(forKey: Key.terminalCursorShape) ?? ""
        ) ?? .block
        terminalCursorBlinking = defaults.object(forKey: Key.terminalCursorBlinking) == nil
            ? true
            : defaults.bool(forKey: Key.terminalCursorBlinking)
        terminalKeybarEnabled = defaults.object(forKey: Key.terminalKeybarEnabled) == nil
            ? true
            : defaults.bool(forKey: Key.terminalKeybarEnabled)
        builtinSnippetsImported = defaults.bool(forKey: Key.builtinSnippetsImported)
        applyAccent()
    }

    var terminalConfiguration: TerminalConfiguration {
        TerminalConfiguration(
            theme: TerminalTheme.theme(id: terminalThemeID),
            fontSize: terminalFontSize,
            scrollback: terminalScrollback,
            cursorShape: terminalCursorShape,
            cursorBlinking: terminalCursorBlinking,
            showsKeybar: terminalKeybarEnabled
        )
    }

    var codeEditorConfiguration: CodeEditorConfiguration {
        CodeEditorConfiguration(
            theme: codeTheme,
            fontSize: codeFontSize,
            showsLineNumbers: codeShowsLineNumbers,
            wrapsLines: codeLineWrapping,
            tabWidth: codeTabWidth,
            indentStyle: codeIndentStyle
        )
    }

    /// 把当前主题色写入 `ConnTheme`（brand = 恢复设计令牌默认）。
    private func applyAccent() {
        if accent == .brand {
            ConnTheme.reset()
        } else {
            ConnTheme.apply(accent.color)
        }
    }

    private enum Key {
        static let appearance = "conn.settings.appearance"
        static let accent = "conn.settings.accent"
        static let refresh = "conn.settings.refreshInterval"
        static let dockerRefresh = "conn.settings.dockerRefreshInterval"
        static let codeTheme = "conn.settings.codeTheme"
        static let codeFontSize = "conn.settings.codeFontSize"
        static let codeShowsLineNumbers = "conn.settings.codeShowsLineNumbers"
        static let codeLineWrapping = "conn.settings.codeLineWrapping"
        static let codeTabWidth = "conn.settings.codeTabWidth"
        static let codeIndentStyle = "conn.settings.codeIndentStyle"
        static let terminalTheme = "conn.settings.terminalTheme"
        static let terminalFontSize = "conn.settings.terminalFontSize"
        static let terminalScrollback = "conn.settings.terminalScrollback"
        static let terminalCursorShape = "conn.settings.terminalCursorShape"
        static let terminalCursorBlinking = "conn.settings.terminalCursorBlinking"
        static let terminalKeybarEnabled = "conn.settings.terminalKeybarEnabled"
        static let builtinSnippetsImported = "conn.settings.builtinSnippetsImported"
    }
}
