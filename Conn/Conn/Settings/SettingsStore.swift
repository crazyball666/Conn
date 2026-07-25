import ConnEditor
import ConnUI
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

/// 主题色预设。`brand` = 设计令牌默认（品牌靛蓝，不覆盖）。
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
    var label: String { String(format: L("每 %d 秒"), rawValue) }
    var duration: Duration { .seconds(rawValue) }
}

/// App 偏好设置（UserDefaults 落盘）。外观即时应用、主题色改单点即整体换肤。
@Observable
@MainActor
final class SettingsStore {
    var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var accent: AppAccent {
        didSet {
            UserDefaults.standard.set(accent.rawValue, forKey: Key.accent)
            applyAccent()
        }
    }

    var refreshInterval: RefreshInterval {
        didSet { UserDefaults.standard.set(refreshInterval.rawValue, forKey: Key.refresh) }
    }

    /// 代码编辑器主题（highlight.js 主题 id）。
    var codeTheme: String {
        didSet { UserDefaults.standard.set(codeTheme, forKey: Key.codeTheme) }
    }

    init() {
        let defaults = UserDefaults.standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        accent = AppAccent(rawValue: defaults.string(forKey: Key.accent) ?? "") ?? .brand
        let storedInterval = defaults.object(forKey: Key.refresh) as? Int ?? RefreshInterval.normal.rawValue
        refreshInterval = RefreshInterval(rawValue: storedInterval) ?? .normal
        codeTheme = defaults.string(forKey: Key.codeTheme) ?? CodeEditorCatalog.defaultThemeID
        applyAccent()
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
        static let codeTheme = "conn.settings.codeTheme"
    }
}
