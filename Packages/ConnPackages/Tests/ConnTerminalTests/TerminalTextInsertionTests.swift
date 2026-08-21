import ConnMultiplexer
import Testing
@testable import ConnTerminal

@Suite("Terminal text insertion")
@MainActor
struct TerminalTextInsertionTests {
    @Test("matching terminal context consumes an insertion exactly once")
    func consumesMatchingRequestOnce() {
        let mailbox = TerminalTextInsertionMailbox()
        let context = TerminalTextInsertionContext(
            tabID: "tab-1",
            generation: 3,
            inputEpoch: 8,
            persistentTarget: .init(
                providerID: "tmux",
                workspaceID: "$1",
                targetID: "%2"
            )
        )
        mailbox.updateContext(context)
        mailbox.enqueue("/repo/image.png ", expectedContext: context)

        #expect(mailbox.consumeIfCurrent() == "/repo/image.png ")
        #expect(mailbox.consumeIfCurrent() == nil)
    }

    @Test("typing, pane changes and PTY rebuilds invalidate an in-flight insertion")
    func rejectsStaleRequests() {
        let initial = TerminalTextInsertionContext(
            tabID: "tab-1",
            generation: 3,
            inputEpoch: 8,
            persistentTarget: .init(
                providerID: "tmux",
                workspaceID: "$1",
                targetID: "%2"
            )
        )

        for staleContext in [
            TerminalTextInsertionContext(
                tabID: "tab-1", generation: 3, inputEpoch: 9,
                persistentTarget: initial.persistentTarget
            ),
            TerminalTextInsertionContext(
                tabID: "tab-1", generation: 3, inputEpoch: 8,
                persistentTarget: .init(
                    providerID: "tmux", workspaceID: "$1", targetID: "%3"
                )
            ),
            TerminalTextInsertionContext(
                tabID: "tab-1", generation: 4, inputEpoch: 8,
                persistentTarget: initial.persistentTarget
            )
        ] {
            let mailbox = TerminalTextInsertionMailbox()
            mailbox.updateContext(initial)
            mailbox.enqueue("/repo/image.png ", expectedContext: initial)
            mailbox.updateContext(staleContext)
            #expect(mailbox.consumeIfCurrent() == nil)
            #expect(mailbox.pending == nil)
        }
    }

    @Test("path rendering rejects terminal control bytes and quotes safe paths")
    func rendersPathsWithoutControlInput() throws {
        #expect(
            try TerminalPathInsertionRenderer.render([
                "/home/user/.conn/uploads/a.png",
                "/repo with spaces/screenshot's final.png"
            ]) == "/home/user/.conn/uploads/a.png '/repo with spaces/screenshot'\\''s final.png' "
        )
        #expect(throws: TerminalPathInsertionError.unsafeControlCharacter) {
            try TerminalPathInsertionRenderer.render(["/tmp/file\nname.png"])
        }
        #expect(throws: TerminalPathInsertionError.unsafeControlCharacter) {
            try TerminalPathInsertionRenderer.render(["/tmp/\u{1B}[201~"])
        }
    }
}
