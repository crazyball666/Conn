import Foundation
import Testing
@testable import ConnTerminal

@Suite("Terminal clipboard policy")
struct TerminalClipboardPolicyTests {
    private let identity = TerminalClipboardSessionIdentity(
        terminalGeneration: 3,
        attachmentGeneration: 5
    )

    @Test("only bounded current-live OSC 52 writes are accepted")
    func writePolicy() {
        let policy = TerminalClipboardPolicy(maximumWriteBytes: 4)

        #expect(policy.acceptsWrite(Data("ok".utf8), provenance: .live(generation: 3), identity: identity))
        #expect(!policy.acceptsWrite(Data("old".utf8), provenance: .replay, identity: identity))
        #expect(!policy.acceptsWrite(Data("edge".utf8), provenance: .generationBoundary, identity: identity))
        #expect(!policy.acceptsWrite(Data("large".utf8), provenance: .live(generation: 3), identity: identity))
        #expect(!policy.acceptsWrite(Data("ok".utf8), provenance: .live(generation: 2), identity: identity))
    }

    @Test("remote OSC 52 reads are always denied")
    func remoteReadsAreDenied() {
        let policy = TerminalClipboardPolicy()

        #expect(!policy.acceptsRead(provenance: .live(generation: 3), identity: identity))
        #expect(!policy.acceptsRead(provenance: .replay, identity: identity))
        #expect(!policy.acceptsRead(
            provenance: .live(generation: 4),
            identity: .init(terminalGeneration: 4, attachmentGeneration: 6)
        ))
    }
}
