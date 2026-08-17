import Foundation
import Testing
@testable import ConnTerminal

@Suite("TerminalTheme — 终端主题目录")
struct TerminalThemeTests {
    @Test("终端默认字体为 10pt")
    func defaultFontSizeIsTenPoints() {
        #expect(TerminalConfiguration.defaultFontSize == 10)
        #expect(TerminalConfiguration().fontSize == 10)
    }

    @Test("内置主题 id、完整配色签名唯一且 ANSI 色完整")
    func catalogIsCompleteAndUnique() {
        let themes = TerminalTheme.all

        #expect(themes.count == 13)
        #expect(Set(themes.map(\.id)).count == themes.count)
        #expect(Set(themes.map(paletteSignature)).count == themes.count)
        #expect(themes.allSatisfy { $0.ansi.count == 16 })
    }

    @Test("主题目录保留全部深色 id 并提供五套浅色主题")
    func catalogContainsExpectedAppearances() {
        let darkIDs = Set(TerminalTheme.all.filter { $0.appearance == .dark }.map(\.id))
        let lightIDs = Set(TerminalTheme.all.filter { $0.appearance == .light }.map(\.id))

        #expect(darkIDs == [
            "conn", "dracula", "solarized-dark", "one-dark", "nord",
            "gruvbox-dark", "tokyo-night", "catppuccin-mocha",
        ])
        #expect(lightIDs == [
            "conn-light", "solarized-light", "gruvbox-light", "one-light",
            "catppuccin-latte",
        ])
    }

    @Test("全部主题前景与背景至少满足 WCAG AA 正文对比度")
    func themesHaveReadableForegroundContrast() {
        for theme in TerminalTheme.all {
            #expect(
                contrast(theme.foreground, theme.background) >= 4.5,
                "\(theme.id) 对比度不足"
            )
        }
    }

    @Test("未知主题仍回退到深色 Conn")
    func unknownThemeFallsBackToConn() {
        let fallback = TerminalTheme.theme(id: "missing")
        #expect(fallback.id == TerminalTheme.conn.id)
        #expect(fallback.appearance == .dark)
    }

    private func paletteSignature(_ theme: TerminalTheme) -> [UInt8] {
        ([theme.background, theme.foreground, theme.cursor] + theme.ansi).flatMap {
            [$0.r, $0.g, $0.b]
        }
    }

    private func contrast(_ lhs: TerminalTheme.RGB, _ rhs: TerminalTheme.RGB) -> Double {
        let high = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let low = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (high + 0.05) / (low + 0.05)
    }

    private func relativeLuminance(_ color: TerminalTheme.RGB) -> Double {
        func component(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * component(color.r)
            + 0.7152 * component(color.g)
            + 0.0722 * component(color.b)
    }
}
