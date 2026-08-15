import CoreGraphics

enum TerminalPanGesturePolicy {
    static func shouldBeginAuxiliaryPan(
        initialVelocity: CGPoint,
        remoteMouseReportingEnabled: Bool
    ) -> Bool {
        remoteMouseReportingEnabled
            || abs(initialVelocity.x) >= abs(initialVelocity.y)
    }
}
