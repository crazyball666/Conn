import Testing
@testable import ConnTerminal

@Suite("Terminal interaction controller")
@MainActor
struct TerminalInteractionControllerTests {
    @Test("one route remains pinned for a gesture and is invalidated by protocol change")
    func pinsRouteAcrossGesture() {
        let controller = TerminalInteractionController()
        controller.update(context(protocolRevision: 4, alternate: true))

        let initial = controller.beginScroll()
        #expect(initial.kind == .plainAlternateKeys)
        #expect(controller.continueScroll().kind == .plainAlternateKeys)

        controller.update(context(protocolRevision: 5, alternate: true))
        #expect(controller.continueScroll().kind == .boundary)

        controller.endScroll()
        #expect(controller.beginScroll().kind == .plainAlternateKeys)
    }

    @Test("review and selection are frozen local states with native tap granularities")
    func reviewAndSelectionTransitions() {
        let controller = TerminalInteractionController()
        let snapshot = review()

        controller.presentReview(snapshot)
        #expect(controller.mode == .review)
        #expect(controller.review?.snapshot == snapshot)

        controller.beginSelection(
            snapshot,
            utf16Offset: 2,
            granularity: .forTapCount(2)
        )
        #expect(controller.mode == .selecting)
        #expect(controller.review?.selection?.granularity == .word)
        #expect(TerminalSelectionGranularity.forTapCount(1) == .character)
        #expect(TerminalSelectionGranularity.forTapCount(3) == .row)
    }

    @Test("Esc exits local modes before allowing a remote Esc")
    func localFirstEscape() {
        let controller = TerminalInteractionController()
        controller.update(context(mouse: .allMotion))

        #expect(controller.activatePointer())
        #expect(controller.mode == .pointer)
        #expect(controller.handleEscape() == .consumedLocally)
        #expect(controller.mode == .live)
        #expect(controller.handleEscape() == .sendToRemote)

        controller.presentReview(review())
        #expect(controller.handleEscape() == .consumedLocally)
        #expect(controller.review == nil)
    }

    @Test("reconnect, pane change, resize and capability loss cancel transient state")
    func invalidatesTransientState() {
        let controller = TerminalInteractionController()
        controller.update(context(mouse: .buttonMotion, targetID: "pane-a"))
        #expect(controller.activatePointer())

        controller.update(context(mouse: .off, targetID: "pane-a"))
        #expect(controller.mode == .live)

        controller.presentReview(review())
        controller.update(context(targetID: "pane-b"))
        #expect(controller.review == nil)

        controller.presentReview(review())
        controller.update(context(columns: 81, targetID: "pane-b"))
        #expect(controller.review == nil)

        controller.presentReview(review(terminalGeneration: 2))
        controller.update(context(terminalGeneration: 3, targetID: "pane-b"))
        #expect(controller.review == nil)
    }

    private func context(
        protocolRevision: UInt64 = 1,
        terminalGeneration: UInt64 = 1,
        columns: Int = 80,
        alternate: Bool = false,
        mouse: TerminalMouseTracking = .off,
        targetID: String? = nil
    ) -> TerminalScrollRouteInput {
        TerminalScrollRouteInput(
            mode: .live,
            protocolState: .init(
                revision: protocolRevision,
                isAlternateBuffer: alternate,
                mouseTracking: mouse,
                bracketedPasteEnabled: false,
                focusReportingEnabled: false,
                applicationCursorEnabled: false,
                columns: columns,
                rows: 24
            ),
            terminalGeneration: terminalGeneration,
            attachmentGeneration: 1,
            persistent: targetID.map {
                .init(
                    revision: 1,
                    freshness: .fresh,
                    isAlternateBuffer: false,
                    modeCapability: .none,
                    historyAvailable: true,
                    targetID: $0
                )
            },
            localHistoryAvailable: true
        )
    }

    private func review(terminalGeneration: UInt64 = 1) -> TerminalReviewSnapshot {
        .init(
            identity: .init(
                terminalGeneration: terminalGeneration,
                attachmentGeneration: 1,
                sourceRevision: 1
            ),
            lines: [.init(text: "value", cellColumnToUTF16Offset: [0, 1, 2, 3, 4, 5], isWrapped: false)],
            visibleLineRange: 0..<1,
            isTruncated: false,
            byteCount: 5
        )
    }
}
