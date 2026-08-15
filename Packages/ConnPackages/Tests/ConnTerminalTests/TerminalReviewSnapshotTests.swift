import ConnMultiplexer
import Foundation
import SwiftTerm
import Testing
@testable import ConnTerminal

@Suite("Terminal review snapshots")
struct TerminalReviewSnapshotTests {
    private let identity = TerminalReviewIdentity(
        terminalGeneration: 7,
        attachmentGeneration: 11,
        sourceRevision: 13
    )

    @Test("untrusted bytes are bounded, normalized and stripped of terminal side effects")
    func sanitizesUntrustedBytes() {
        let bytes = Data(
            "old\r\n\u{1B}]52;c;ZXZpbA==\u{7}middle\rnew\u{1B}Ppayload\u{1B}\\\nlast\u{0}"
                .utf8
        )

        let snapshot = TerminalReviewSnapshot.sanitizing(
            bytes,
            identity: identity,
            maximumLines: 3,
            maximumBytes: bytes.count - 1
        )

        #expect(snapshot.lines.map(\.text) == ["middle", "new", "last"])
        #expect(snapshot.isTruncated)
        #expect(snapshot.byteCount == bytes.count - 1)
        #expect(snapshot.identity == identity)
        #expect(snapshot.text == "middle\nnew\nlast")
    }

    @Test("malformed UTF-8 is replaced and tabs remain inert text")
    func replacesMalformedUTF8() {
        let snapshot = TerminalReviewSnapshot.sanitizing(
            Data([0x41, 0x09, 0xFF, 0x42]),
            identity: identity,
            maximumLines: 10,
            maximumBytes: 10
        )

        #expect(snapshot.lines.map(\.text) == ["A\t�B"])
        #expect(!snapshot.isTruncated)
    }

    @Test("SwiftTerm snapshots preserve viewport and cell mappings")
    func adaptsSwiftTermSnapshot() {
        let source = TerminalBufferSnapshot(
            scope: .normalHistory,
            protocolRevision: 13,
            columns: 4,
            rows: 2,
            sourceStartLine: 0,
            visibleLineRange: 1..<3,
            lines: [
                .init(
                    text: "wide",
                    cellColumnToUTF16Offset: [0, 1, 1, 3, 4],
                    styles: [],
                    isWrapped: true
                ),
                .init(
                    text: "tail",
                    cellColumnToUTF16Offset: [0, 1, 2, 3, 4],
                    styles: [],
                    isWrapped: false
                ),
                .init(
                    text: "view",
                    cellColumnToUTF16Offset: [0, 1, 2, 3, 4],
                    styles: [],
                    isWrapped: false
                ),
            ]
        )

        let snapshot = TerminalReviewSnapshot(
            swiftTerm: source,
            terminalGeneration: 7,
            attachmentGeneration: 11
        )

        #expect(snapshot.identity == identity)
        #expect(snapshot.visibleLineRange == 1..<3)
        #expect(snapshot.text == "widetail\nview")
        #expect(snapshot.utf16Offset(line: 0, column: 2) == 1)
        #expect(snapshot.utf16Offset(line: 1, column: 2) == 6)
    }

    @Test("persistent snapshots remain provider-neutral and clamp invalid metadata")
    func adaptsPersistentSnapshot() {
        let source = PersistentTerminalHistorySnapshot(
            target: .init(providerID: "future", workspaceID: "workspace", targetID: "pane"),
            attachmentGeneration: 11,
            stateRevision: 13,
            capturedAt: .init(timeIntervalSince1970: 1),
            lines: [
                .init(text: "first", cellColumnToUTF16Offset: [0, 1, 2, 3, 4, 5], isWrapped: false),
                .init(text: "second", cellColumnToUTF16Offset: [0, 1, 2, 3, 4, 5, 6], isWrapped: false),
            ],
            visibleLineRange: -4..<99,
            isTruncated: true,
            byteCount: 12
        )

        let snapshot = TerminalReviewSnapshot(
            persistent: source,
            terminalGeneration: 7
        )

        #expect(snapshot.identity == identity)
        #expect(snapshot.visibleLineRange == 0..<2)
        #expect(snapshot.isTruncated)
        #expect(snapshot.text == "first\nsecond")
    }
}
