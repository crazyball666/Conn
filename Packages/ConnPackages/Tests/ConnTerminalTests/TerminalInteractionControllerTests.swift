import Testing
@testable import ConnTerminal

@Suite("Terminal interaction controller")
@MainActor
struct TerminalInteractionControllerTests {
    @Test("水平滑动只接受明显横向手势并要求足够位移或甩动速度")
    func horizontalSwipeClassification() {
        let classifier = TerminalHorizontalSwipeClassifier()

        #expect(classifier.canBegin(velocityX: 500, velocityY: 100))
        #expect(!classifier.canBegin(velocityX: 100, velocityY: 500))
        #expect(!classifier.canBegin(velocityX: 100, velocityY: 20))
        #expect(classifier.completedDirection(
            translationX: -60,
            translationY: 10,
            velocityX: -500,
            velocityY: 100
        ) == .left)
        #expect(classifier.completedDirection(
            translationX: 10,
            translationY: 4,
            velocityX: 800,
            velocityY: 100
        ) == .right)
        #expect(classifier.completedDirection(
            translationX: 20,
            translationY: 5,
            velocityX: 400,
            velocityY: 50
        ) == nil)
        #expect(classifier.completedDirection(
            translationX: -60,
            translationY: 10,
            velocityX: 0,
            velocityY: 0
        ) == .left)
    }

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

    @Test("远端声明鼠标协议时普通单击直接发送主按钮点击")
    func directTapUsesRemoteMouseWithoutPointerMode() {
        let controller = TerminalInteractionController()

        controller.update(context(mouse: .pressAndRelease))
        #expect(controller.mode == .live)
        #expect(controller.directTapAction() == .remotePrimaryClick)

        controller.update(context(mouse: .off))
        #expect(controller.directTapAction() == .focusOnly)
    }

    @Test("本地 Review 和选词状态不会把单击泄漏给远端")
    func frozenLocalModesKeepDirectTapLocal() {
        let controller = TerminalInteractionController()
        controller.update(context(mouse: .allMotion))

        controller.presentReview(review())
        #expect(controller.directTapAction() == .focusOnly)

        controller.beginSelection(
            review(),
            utf16Offset: 0,
            granularity: .character
        )
        #expect(controller.directTapAction() == .focusOnly)
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
