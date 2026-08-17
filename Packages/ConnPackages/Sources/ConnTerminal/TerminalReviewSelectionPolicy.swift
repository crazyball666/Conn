import Foundation

enum TerminalReviewEditAction: Sendable, Equatable {
    case copy
    case selectAll
    case done
}

enum TerminalReviewEditEffect: Sendable, Equatable {
    case copy(text: String, dismisses: Bool)
    case selection(NSRange)
    case dismiss
    case none
}

enum TerminalReviewSelectionPolicy {
    static func wordRange(in text: String, utf16Offset: Int) -> NSRange {
        let source = text as NSString
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let offset = min(max(utf16Offset, 0), source.length - 1)
        var result: NSRange?

        text.enumerateSubstrings(
            in: text.startIndex ..< text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            let candidate = NSRange(range, in: text)
            guard NSLocationInRange(offset, candidate) else { return }
            result = candidate
            stop = true
        }

        return result ?? source.rangeOfComposedCharacterSequence(at: offset)
    }

    static func effect(
        for action: TerminalReviewEditAction,
        text: String,
        selectedRange: NSRange
    ) -> TerminalReviewEditEffect {
        let source = text as NSString
        switch action {
        case .selectAll:
            return .selection(NSRange(location: 0, length: source.length))
        case .done:
            return .dismiss
        case .copy:
            guard selectedRange.location != NSNotFound,
                  selectedRange.length > 0,
                  selectedRange.location <= source.length,
                  NSMaxRange(selectedRange) <= source.length
            else { return .none }
            return .copy(text: source.substring(with: selectedRange), dismisses: true)
        }
    }
}
