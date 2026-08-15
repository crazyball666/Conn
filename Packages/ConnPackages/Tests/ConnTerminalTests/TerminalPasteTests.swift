import Testing
@testable import ConnTerminal

@Suite("Terminal typed input planning")
struct TerminalPasteTests {
    @Test("keybar and system paste converge on one typed paste action")
    func pasteSourcesConverge() {
        let planner = TerminalTypedInputPlanner()

        #expect(planner.paste("value", source: .keybar) == .paste("value"))
        #expect(planner.paste("value", source: .systemMenu) == .paste("value"))
    }

    @Test("focus reporting follows responder and application state without duplicates")
    func focusTransitions() {
        var focus = TerminalFocusState()

        #expect(focus.setFirstResponder(true) == nil)
        #expect(focus.setApplicationActive(true) == true)
        #expect(focus.setApplicationActive(true) == nil)
        #expect(focus.setFirstResponder(false) == false)
        #expect(focus.setApplicationActive(false) == nil)
    }

    @Test("feed provenance exposes side effects only for the current live generation")
    func feedProvenance() {
        let gate = TerminalReplayOutboundGate()

        gate.withFeed(.replay) {
            #expect(!gate.allowsHostSideEffects)
            #expect(!gate.allowsTerminalDelegateOutput)
        }
        gate.withFeed(.generationBoundary) {
            #expect(!gate.allowsHostSideEffects)
            #expect(!gate.allowsTerminalDelegateOutput)
        }
        gate.withFeed(.live(generation: 9)) {
            #expect(gate.allowsHostSideEffects)
            #expect(gate.currentFeedProvenance == .live(generation: 9))
            #expect(gate.allowsTerminalDelegateOutput)
        }
    }
}
