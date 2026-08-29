import Foundation
import Testing
@testable import SwiftTerm

@Suite("Conn host interaction boundary")
struct TerminalHostInteractionTests {
    private final class Delegate: TerminalDelegate {
        var sent: [UInt8] = []
        var copied: [Data] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }

        func clipboardCopy(source: Terminal, content: Data) {
            copied.append(content)
        }
    }

    @Test("paste uses bracketed framing exactly once when enabled")
    func pasteFraming() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)

        terminal.paste(text: "hello")
        #expect(String(bytes: delegate.sent, encoding: .utf8) == "hello")

        delegate.sent.removeAll()
        terminal.feed(text: "\u{1b}[?2004h")
        terminal.paste(text: "world")
        #expect(String(bytes: delegate.sent, encoding: .utf8) == "\u{1b}[200~world\u{1b}[201~")
    }

    @Test("protocol revision advances only for routing-relevant transitions")
    func protocolRevision() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let initial = terminal.hostProtocolState
        var callbacks: [TerminalHostProtocolState] = []
        terminal.onHostProtocolStateChanged = { callbacks.append($0) }

        terminal.feed(text: "ordinary output")
        #expect(terminal.hostProtocolState.revision == initial.revision)

        terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[?1h")
        let changed = terminal.hostProtocolState
        #expect(changed.revision > initial.revision)
        #expect(changed.isAlternateBuffer)
        #expect(changed.mouseMode != .off)
        #expect(changed.mouseEncoding == .sgr)
        #expect(changed.bracketedPasteEnabled)
        #expect(changed.focusReportingEnabled)
        #expect(changed.applicationCursorEnabled)
        #expect(changed.alternateScrollEnabled)
        #expect(callbacks.last == changed)

        let beforeAlternateScroll = changed.revision
        terminal.feed(text: "\u{1b}[?1007l")
        #expect(!terminal.hostProtocolState.alternateScrollEnabled)
        #expect(terminal.hostProtocolState.revision > beforeAlternateScroll)

        terminal.feed(text: "\u{1b}[?1007h")
        #expect(terminal.hostProtocolState.alternateScrollEnabled)

        terminal.resize(cols: 100, rows: 40)
        #expect(terminal.hostProtocolState.revision > changed.revision)
    }

    @Test("typed cursor keys honor application cursor mode")
    func cursorKeys() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)

        terminal.sendHostCursorKey(.up, count: 2)
        #expect(String(bytes: delegate.sent, encoding: .utf8) == "\u{1b}[A\u{1b}[A")

        delegate.sent.removeAll()
        terminal.feed(text: "\u{1b}[?1h")
        terminal.sendHostCursorKey(.down, count: 1)
        #expect(String(bytes: delegate.sent, encoding: .utf8) == "\u{1b}OB")
    }

    @Test("typed mouse uses active SGR encoding and clamps coordinates")
    func typedMouse() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 5))
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")

        terminal.sendHostWheel(
            direction: .up,
            count: 1,
            at: TerminalInteractionHit(column: 99, row: 99, pixelX: 999, pixelY: 999),
            modifiers: []
        )

        #expect(String(bytes: delegate.sent, encoding: .utf8) == "\u{1b}[<64;10;5M")
    }

    @Test("typed pointer suppresses events unsupported by the active tracking mode")
    func typedPointerHonorsTrackingMode() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let hit = TerminalInteractionHit(column: 1, row: 1, pixelX: 1, pixelY: 1)

        terminal.feed(text: "\u{1b}[?9h")
        terminal.sendHostPointer(.press(button: 0), at: hit, modifiers: [])
        #expect(!delegate.sent.isEmpty)

        delegate.sent.removeAll()
        terminal.sendHostPointer(.release(button: 0), at: hit, modifiers: [])
        terminal.sendHostPointer(.motion(button: 0), at: hit, modifiers: [])
        #expect(delegate.sent.isEmpty)

        terminal.feed(text: "\u{1b}[?9l\u{1b}[?1002h")
        terminal.sendHostPointer(.motion(button: 0), at: hit, modifiers: [])
        #expect(!delegate.sent.isEmpty)
    }

    @Test("snapshots are immutable and retain cell-to-text mappings")
    func immutableSnapshot() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 8, rows: 2, scrollback: 10))
        terminal.feed(text: "abc")
        let snapshot = terminal.makeHostSnapshot(.visible)

        terminal.feed(text: "def")

        #expect(snapshot.lines.first?.text.hasPrefix("abc") == true)
        #expect(snapshot.lines.first?.cellColumnToUTF16Offset.count == 9)
        #expect(snapshot != terminal.makeHostSnapshot(.visible))
    }

    @Test("OSC 52 rejects oversized payloads before delegate delivery")
    func boundedOSC52() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let oversized = Data(repeating: 0x61, count: Terminal.osc52MaximumDecodedBytes + 128)
            .base64EncodedString()

        terminal.feed(text: "\u{1b}]52;c;\(oversized)\u{07}")

        #expect(delegate.copied.isEmpty)
        #expect(terminal.parser.osc52OverflowCount == 1)
    }
}
