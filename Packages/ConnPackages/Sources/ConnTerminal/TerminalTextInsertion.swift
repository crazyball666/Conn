import Combine
import ConnMultiplexer
import Foundation

/// Identity of the exact terminal input target captured before an asynchronous operation.
/// The input epoch advances on user input, so a completed upload cannot be inserted into a
/// prompt that changed while the picker or transfer was active.
public struct TerminalTextInsertionContext: Sendable, Equatable {
    public let tabID: String
    public let generation: UInt64
    public let inputEpoch: UInt64
    public let persistentTarget: PersistentTerminalInteractionTarget?

    public init(
        tabID: String,
        generation: UInt64,
        inputEpoch: UInt64,
        persistentTarget: PersistentTerminalInteractionTarget?
    ) {
        self.tabID = tabID
        self.generation = generation
        self.inputEpoch = inputEpoch
        self.persistentTarget = persistentTarget
    }
}

public struct TerminalTextInsertionRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let expectedContext: TerminalTextInsertionContext

    public init(
        id: UUID = UUID(),
        text: String,
        expectedContext: TerminalTextInsertionContext
    ) {
        self.id = id
        self.text = text
        self.expectedContext = expectedContext
    }
}

/// A screen-scoped, one-shot mailbox. Text is consumed only by the same tab, PTY
/// generation, input epoch and provider target that initiated the operation.
@MainActor
public final class TerminalTextInsertionMailbox: ObservableObject {
    @Published public private(set) var currentContext: TerminalTextInsertionContext?
    @Published public private(set) var pending: TerminalTextInsertionRequest?
    #if DEBUG
        @Published public private(set) var lastConsumedText: String?
    #endif

    public init() {}

    public func updateContext(_ context: TerminalTextInsertionContext) {
        currentContext = context
        if let pending, pending.expectedContext != context {
            self.pending = nil
        }
    }

    public func enqueue(_ text: String, expectedContext: TerminalTextInsertionContext) {
        guard expectedContext == currentContext else {
            pending = nil
            return
        }
        pending = .init(text: text, expectedContext: expectedContext)
    }

    public func consumeIfCurrent() -> String? {
        guard let request = pending else { return nil }
        pending = nil
        guard request.expectedContext == currentContext else { return nil }
        #if DEBUG
            lastConsumedText = request.text
        #endif
        return request.text
    }
}

public enum TerminalPathInsertionError: Error, Sendable, Equatable {
    case unsafeControlCharacter
}

/// Renders paths as one shell-compatible token sequence without command submission.
/// C0/DEL controls are rejected so bracketed paste can never carry CR, LF or ESC.
public enum TerminalPathInsertionRenderer {
    public static func render(_ paths: [String]) throws -> String {
        let rendered = try paths.map(renderPath)
        guard !rendered.isEmpty else { return "" }
        return rendered.joined(separator: " ") + " "
    }

    private static func renderPath(_ path: String) throws -> String {
        guard !path.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }) else {
            throw TerminalPathInsertionError.unsafeControlCharacter
        }
        let safeUnquoted = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "/._-+%:@="))
        if path.unicodeScalars.allSatisfy(safeUnquoted.contains) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
