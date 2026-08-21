import Testing
@testable import ConnTerminal

@Suite("Terminal tool command catalog")
struct TerminalToolCommandCatalogTests {
    @Test("Claude Code catalog covers common session, workflow and diagnostic commands")
    func claudeCodeCatalogContents() {
        let catalog = TerminalToolCommandCatalog.claudeCode
        let actions = catalog.sections.flatMap(\.actions)

        #expect(catalog.id == "claude-code")
        #expect(catalog.sections.map(\.id) == ["session", "workflow", "configuration"])
        #expect(actions.count == 18)
        #expect(Set(actions.map(\.command)) == [
            "/clear", "/compact", "/context", "/resume", "/rewind", "/status",
            "/plan", "/diff", "/review", "/tasks", "/memory", "/mcp",
            "/model", "/permissions", "/usage", "/config", "/doctor", "/help"
        ])
    }

    @Test("tool commands are unique insertion-only payloads without terminal controls")
    func commandsAreSafeInsertionPayloads() {
        let actions = TerminalToolCommandCatalog.claudeCode.sections.flatMap(\.actions)

        #expect(Set(actions.map(\.id)).count == actions.count)
        #expect(actions.allSatisfy { $0.command.hasPrefix("/") })
        #expect(actions.allSatisfy { action in
            !action.command.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F
            }
        })
    }
}
