import Foundation

struct TerminalClipboardSessionIdentity: Sendable, Equatable {
    let terminalGeneration: UInt64
    let attachmentGeneration: UInt64

    init(terminalGeneration: UInt64, attachmentGeneration: UInt64) {
        self.terminalGeneration = terminalGeneration
        self.attachmentGeneration = attachmentGeneration
    }
}

struct TerminalClipboardPolicy: Sendable {
    let maximumWriteBytes: Int

    init(maximumWriteBytes: Int = 1_048_576) {
        self.maximumWriteBytes = max(maximumWriteBytes, 0)
    }

    func acceptsWrite(
        _ content: Data,
        provenance: TerminalFeedProvenance,
        identity: TerminalClipboardSessionIdentity
    ) -> Bool {
        guard content.count <= maximumWriteBytes else { return false }
        guard case let .live(generation) = provenance else { return false }
        return generation == identity.terminalGeneration
    }

    func acceptsRead(
        provenance: TerminalFeedProvenance,
        identity: TerminalClipboardSessionIdentity
    ) -> Bool {
        // Remote clipboard queries can expose passwords and one-time codes. Conn supports
        // explicit local paste and bounded remote-to-local writes, but never lets OSC 52
        // pull the device clipboard into a remote process.
        _ = (provenance, identity)
        return false
    }
}
