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

    @Test("clipboard read authority lasts 30 seconds and is consumed exactly once")
    func oneShotReadAuthority() {
        var policy = TerminalClipboardPolicy()
        let now = Date(timeIntervalSince1970: 100)

        var consumed = policy.consumeReadAuthority(for: identity, now: now)
        #expect(!consumed)
        policy.grantReadOnce(for: identity, now: now)
        consumed = policy.consumeReadAuthority(for: identity, now: now.addingTimeInterval(30))
        #expect(consumed)
        consumed = policy.consumeReadAuthority(for: identity, now: now.addingTimeInterval(30))
        #expect(!consumed)

        policy.grantReadOnce(for: identity, now: now)
        consumed = policy.consumeReadAuthority(for: identity, now: now.addingTimeInterval(30.001))
        #expect(!consumed)
    }

    @Test("an attempted read consumes authority even when the clipboard later fails")
    func failedReadStillConsumesToken() {
        var policy = TerminalClipboardPolicy()
        let now = Date(timeIntervalSince1970: 100)
        policy.grantReadOnce(for: identity, now: now)

        var consumed = policy.consumeReadAuthority(for: identity, now: now)
        #expect(consumed)
        // The pasteboard adapter returned nil; policy must not renew the grant.
        consumed = policy.consumeReadAuthority(for: identity, now: now)
        #expect(!consumed)
    }

    @Test("authority is generation scoped and explicitly clearable on lifecycle boundaries")
    func lifecycleScope() {
        var policy = TerminalClipboardPolicy()
        let now = Date(timeIntervalSince1970: 100)
        policy.grantReadOnce(for: identity, now: now)

        let reconnected = TerminalClipboardSessionIdentity(
            terminalGeneration: 4,
            attachmentGeneration: 6
        )
        var consumed = policy.consumeReadAuthority(for: reconnected, now: now)
        #expect(!consumed)

        policy.grantReadOnce(for: identity, now: now)
        policy.clearReadAuthority()
        consumed = policy.consumeReadAuthority(for: identity, now: now)
        #expect(!consumed)
    }
}
