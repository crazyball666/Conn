import ConnEditor
import ConnTerminal
import Foundation
import Testing
@testable import Conn

@Suite("SettingsStore — 设置持久化")
@MainActor
struct SettingsStoreTests {
    @Test("隐私政策使用正式官网的 HTTPS 地址")
    func privacyPolicyLinkUsesPublishedWebsite() {
        let url = AppLegalLinks.privacyPolicyURL
        #expect(url?.absoluteString == "https://crazyball.cc/ConnTerm/privacy/")
    }

    @Test("首次启动默认使用深色模式和紫色主题")
    func firstLaunchUsesDarkPurpleDefaults() {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.appearance == .dark)
        #expect(settings.accent == .purple)
        #expect(settings.terminalFontSize == 10)
        #expect(settings.terminalConfiguration.fontSize == 10)
    }

    @Test("终端设置写入 UserDefaults 并可恢复")
    func terminalSettingsPersist() {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.terminalThemeID = TerminalTheme.tokyoNight.id
        settings.terminalFontSize = 17
        settings.terminalScrollback = 5_000
        settings.terminalCursorShape = .bar
        settings.terminalCursorBlinking = false
        settings.terminalKeybarEnabled = false

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.terminalThemeID == TerminalTheme.tokyoNight.id)
        #expect(restored.terminalFontSize == 17)
        #expect(restored.terminalScrollback == 5_000)
        #expect(restored.terminalCursorShape == .bar)
        #expect(!restored.terminalCursorBlinking)
        #expect(!restored.terminalKeybarEnabled)
    }

    @Test("编辑器设置写入 UserDefaults 并可恢复")
    func editorSettingsPersist() {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.codeTheme = "dracula"
        settings.codeFontSize = 17
        settings.codeShowsLineNumbers = false
        settings.codeLineWrapping = false
        settings.codeTabWidth = 2
        settings.codeIndentStyle = .tabs

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.codeTheme == "dracula")
        #expect(restored.codeFontSize == 17)
        #expect(!restored.codeShowsLineNumbers)
        #expect(!restored.codeLineWrapping)
        #expect(restored.codeTabWidth == 2)
        #expect(restored.codeIndentStyle == .tabs)
    }

    @Test("非法编辑器数值恢复为支持的默认值")
    func invalidEditorSettingsUseDefaults() {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(99, forKey: "conn.settings.codeFontSize")
        defaults.set(3, forKey: "conn.settings.codeTabWidth")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.codeFontSize == 13)
        #expect(settings.codeTabWidth == 4)
    }
}
