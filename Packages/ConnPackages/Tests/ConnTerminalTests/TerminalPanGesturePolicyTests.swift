import Testing
@testable import ConnTerminal

@Suite("Terminal pan gesture policy")
struct TerminalPanGesturePolicyTests {
    @Test("Native scroll pan remains available")
    func nativeScrollPanRemainsAvailable() {
        #expect(TerminalPanGesturePolicy.shouldBeginPan(isNativeScrollPan: true))
    }

    @Test("Every auxiliary pan is disabled")
    func auxiliaryPanIsDisabled() {
        #expect(!TerminalPanGesturePolicy.shouldBeginPan(isNativeScrollPan: false))
    }
}
