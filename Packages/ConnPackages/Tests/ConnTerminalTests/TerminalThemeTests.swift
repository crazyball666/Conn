import Testing
@testable import ConnTerminal

@Suite("TerminalTheme — 终端主题目录")
struct TerminalThemeTests {
    @Test("内置主题 id 唯一且每套都有完整 ANSI 16 色")
    func catalogIsComplete() {
        let themes = TerminalTheme.all

        #expect(themes.count == 8)
        #expect(Set(themes.map(\.id)).count == themes.count)
        #expect(themes.allSatisfy { $0.ansi.count == 16 })
    }

    @Test("未知主题回退到 Conn")
    func unknownThemeFallsBackToConn() {
        #expect(TerminalTheme.theme(id: "missing").id == TerminalTheme.conn.id)
    }
}
