import Foundation

public enum TerminalSelectionGranularity: Sendable, Equatable {
    case character
    case word
    case row

    public static func forTapCount(_ count: Int) -> TerminalSelectionGranularity {
        switch count {
        case 2: .word
        case 3...: .row
        default: .character
        }
    }
}

public struct TerminalReviewSelection: Sendable, Equatable {
    public let utf16Offset: Int
    public let granularity: TerminalSelectionGranularity

    public init(utf16Offset: Int, granularity: TerminalSelectionGranularity) {
        self.utf16Offset = max(utf16Offset, 0)
        self.granularity = granularity
    }
}

public struct TerminalReviewPresentation: Sendable, Equatable {
    public let snapshot: TerminalReviewSnapshot
    public let selection: TerminalReviewSelection?

    public init(snapshot: TerminalReviewSnapshot, selection: TerminalReviewSelection?) {
        self.snapshot = snapshot
        self.selection = selection
    }
}

public enum TerminalEscapeDisposition: Sendable, Equatable {
    case consumedLocally
    case sendToRemote
}

/// Main-actor state machine for gesture routing and frozen review state. It deliberately
/// owns no UIKit recognizers and performs no provider I/O; the host view executes its typed
/// decisions and validates their route token before every asynchronous continuation.
@MainActor
public final class TerminalInteractionController {
    public private(set) var mode: TerminalInteractionMode = .live
    public private(set) var review: TerminalReviewPresentation?
    public private(set) var context: TerminalScrollRouteInput?

    private let router: TerminalScrollRouter
    private var pinnedScrollAction: TerminalScrollAction?
    private var scrollIsActive = false

    public init(router: TerminalScrollRouter = .init()) {
        self.router = router
    }

    public var pointerAvailable: Bool {
        context?.protocolState.mouseTracking.reportsMouse == true
    }

    public func update(_ newContext: TerminalScrollRouteInput) {
        let oldContext = context
        context = newContext

        if let token = pinnedScrollAction?.token, !token.matches(newContext) {
            pinnedScrollAction = nil
        }

        if shouldInvalidateFrozenState(old: oldContext, new: newContext) {
            dismissReview()
        }
        if mode == .pointer, !newContext.protocolState.mouseTracking.reportsMouse {
            mode = .live
        }
    }

    public func beginScroll(
        modeOverride: TerminalInteractionMode? = nil
    ) -> TerminalScrollAction {
        scrollIsActive = true
        guard var input = context else { return fallbackBoundary() }
        input = replacingMode(in: input, modeOverride: modeOverride)
        let action = router.route(input)
        pinnedScrollAction = action
        return action
    }

    public func continueScroll() -> TerminalScrollAction {
        guard scrollIsActive else { return fallbackBoundary() }
        guard let action = pinnedScrollAction,
              let context,
              action.token?.matches(replacingMode(in: context)) != false
        else {
            return fallbackBoundary()
        }
        return action
    }

    public func endScroll() {
        scrollIsActive = false
        pinnedScrollAction = nil
    }

    @discardableResult
    public func activatePointer() -> Bool {
        guard pointerAvailable else { return false }
        dismissReview()
        mode = .pointer
        return true
    }

    public func deactivatePointer() {
        if mode == .pointer { mode = .live }
    }

    public func presentReview(_ snapshot: TerminalReviewSnapshot) {
        endScroll()
        mode = .review
        review = .init(snapshot: snapshot, selection: nil)
    }

    public func beginSelection(
        _ snapshot: TerminalReviewSnapshot,
        utf16Offset: Int,
        granularity: TerminalSelectionGranularity
    ) {
        endScroll()
        mode = .selecting
        review = .init(
            snapshot: snapshot,
            selection: .init(utf16Offset: utf16Offset, granularity: granularity)
        )
    }

    public func dismissReview() {
        review = nil
        if mode == .review || mode == .selecting { mode = .live }
    }

    public func handleEscape() -> TerminalEscapeDisposition {
        switch mode {
        case .live:
            return .sendToRemote
        case .review, .selecting:
            dismissReview()
            return .consumedLocally
        case .pointer:
            deactivatePointer()
            return .consumedLocally
        }
    }

    public func invalidate() {
        endScroll()
        review = nil
        mode = .live
        context = nil
    }

    private func replacingMode(
        in input: TerminalScrollRouteInput,
        modeOverride: TerminalInteractionMode? = nil
    ) -> TerminalScrollRouteInput {
        .init(
            mode: modeOverride ?? mode,
            protocolState: input.protocolState,
            terminalGeneration: input.terminalGeneration,
            attachmentGeneration: input.attachmentGeneration,
            persistent: input.persistent,
            localHistoryAvailable: input.localHistoryAvailable
        )
    }

    private func shouldInvalidateFrozenState(
        old: TerminalScrollRouteInput?,
        new: TerminalScrollRouteInput
    ) -> Bool {
        guard review != nil, let old else { return false }
        return old.terminalGeneration != new.terminalGeneration
            || old.attachmentGeneration != new.attachmentGeneration
            || old.protocolState.columns != new.protocolState.columns
            || old.protocolState.rows != new.protocolState.rows
            || old.persistent?.targetID != new.persistent?.targetID
    }

    private func fallbackBoundary() -> TerminalScrollAction {
        let input = replacingMode(in: context ?? Self.emptyContext)
        return .boundary(TerminalRouteToken(input))
    }

    private static let emptyContext = TerminalScrollRouteInput(
        mode: .live,
        protocolState: .init(
            revision: 0,
            isAlternateBuffer: false,
            mouseTracking: .off,
            bracketedPasteEnabled: false,
            focusReportingEnabled: false,
            applicationCursorEnabled: false,
            columns: 0,
            rows: 0
        ),
        terminalGeneration: 0,
        attachmentGeneration: 0,
        persistent: nil,
        localHistoryAvailable: false
    )
}
