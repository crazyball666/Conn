public enum TerminalPasteSource: Sendable, Equatable {
    case keybar
    case systemMenu
}

public enum TerminalTypedInputAction: Sendable, Equatable {
    case paste(String)
}

public struct TerminalTypedInputPlanner: Sendable {
    public init() {}

    public func paste(
        _ text: String,
        source: TerminalPasteSource
    ) -> TerminalTypedInputAction {
        // The source is intentionally provenance only: neither system paste nor the keybar
        // may bypass the emulator's active bracketed-paste framing.
        _ = source
        return .paste(text)
    }
}

public struct TerminalFocusState: Sendable {
    private var isFirstResponder = false
    private var isApplicationActive = false
    private var lastReportedFocus = false

    public init() {}

    public mutating func setFirstResponder(_ value: Bool) -> Bool? {
        isFirstResponder = value
        return transition()
    }

    public mutating func setApplicationActive(_ value: Bool) -> Bool? {
        isApplicationActive = value
        return transition()
    }

    private mutating func transition() -> Bool? {
        let focused = isFirstResponder && isApplicationActive
        guard focused != lastReportedFocus else { return nil }
        lastReportedFocus = focused
        return focused
    }
}
