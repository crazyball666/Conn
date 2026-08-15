import CoreGraphics
import Testing
@testable import ConnTerminal

@Suite("Terminal pan gesture policy")
struct TerminalPanGesturePolicyTests {
    @Test("Vertical auxiliary pan yields to native scroll")
    func verticalPanYieldsToNativeScroll() {
        let shouldBegin = TerminalPanGesturePolicy.shouldBeginAuxiliaryPan(
            initialVelocity: CGPoint(x: 4, y: -40),
            remoteMouseReportingEnabled: false
        )

        #expect(!shouldBegin)
    }

    @Test("Horizontal auxiliary pan remains available for selection")
    func horizontalPanRemainsAvailableForSelection() {
        let shouldBegin = TerminalPanGesturePolicy.shouldBeginAuxiliaryPan(
            initialVelocity: CGPoint(x: 40, y: -4),
            remoteMouseReportingEnabled: false
        )

        #expect(shouldBegin)
    }

    @Test("Balanced auxiliary pan remains available for selection")
    func balancedPanRemainsAvailableForSelection() {
        let shouldBegin = TerminalPanGesturePolicy.shouldBeginAuxiliaryPan(
            initialVelocity: CGPoint(x: 20, y: -20),
            remoteMouseReportingEnabled: false
        )

        #expect(shouldBegin)
    }

    @Test("Remote mouse reporting keeps ownership of vertical pans")
    func remoteMouseReportingBypassesLocalDirectionPolicy() {
        let shouldBegin = TerminalPanGesturePolicy.shouldBeginAuxiliaryPan(
            initialVelocity: CGPoint(x: 0, y: -40),
            remoteMouseReportingEnabled: true
        )

        #expect(shouldBegin)
    }
}
