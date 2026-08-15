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
    static let readAuthorityLifetime: TimeInterval = 30

    private struct ReadAuthority: Sendable {
        let identity: TerminalClipboardSessionIdentity
        let expiresAt: Date
    }

    let maximumWriteBytes: Int
    private var readAuthority: ReadAuthority?

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

    mutating func grantReadOnce(
        for identity: TerminalClipboardSessionIdentity,
        now: Date = .now
    ) {
        readAuthority = .init(
            identity: identity,
            expiresAt: now.addingTimeInterval(Self.readAuthorityLifetime)
        )
    }

    /// Consumes before the pasteboard is accessed, so a failed or empty system read cannot
    /// accidentally turn one user grant into multiple terminal reads.
    mutating func consumeReadAuthority(
        for identity: TerminalClipboardSessionIdentity,
        now: Date = .now
    ) -> Bool {
        guard let authority = readAuthority else { return false }
        readAuthority = nil
        return authority.identity == identity && now <= authority.expiresAt
    }

    mutating func clearReadAuthority() {
        readAuthority = nil
    }
}
