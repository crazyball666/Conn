import CoreGraphics
import Testing
@testable import ConnTerminal

/// 摇杆的全部逻辑就是「落点 → 方向」这一个纯函数，其余是手势与计时器。
@Suite("TerminalDirectionPad — 落点方向判定")
struct TerminalDirectionPadTests {
    private let size = CGSize(width: 80, height: 80)

    private func direction(_ x: CGFloat, _ y: CGFloat) -> TerminalKey? {
        TerminalDirectionResolver.direction(for: CGPoint(x: x, y: y), in: size)
    }

    @Test("四个正方向")
    func cardinalDirections() {
        #expect(direction(40, 4) == .up)
        #expect(direction(40, 76) == .down)
        #expect(direction(4, 40) == .left)
        #expect(direction(76, 40) == .right)
    }

    /// 中心死区：手指停在正中时不该来回抖出方向。
    @Test("死区内不产生方向")
    func deadZone() {
        #expect(direction(40, 40) == nil)
        #expect(direction(44, 40) == nil, "距中心 4pt，仍在 10pt 死区内")
        #expect(direction(52, 40) == .right, "距中心 12pt，已越过死区")
    }

    /// 对角线附近按 |dx| 与 |dy| 谁大分象限，各占 90°，不产生歧义。
    @Test("对角线附近按较大分量归属象限")
    func diagonalResolution() {
        // 右上：dx=+30, dy=-20 → 水平分量更大 → right
        #expect(direction(70, 20) == .right)
        // 右上：dx=+20, dy=-30 → 垂直分量更大 → up
        #expect(direction(60, 10) == .up)
    }

    /// 边角也要有确定答案，不能返回 nil 让用户按了没反应。
    @Test("四角各归一个方向，不返回 nil")
    func cornersResolve() {
        #expect(direction(0, 0) != nil)
        #expect(direction(80, 0) != nil)
        #expect(direction(0, 80) != nil)
        #expect(direction(80, 80) != nil)
    }

    /// 摇杆是正方形，但判定不该写死尺寸——换边长后中心随之移动。
    @Test("判定随控件尺寸缩放")
    func scalesWithSize() {
        let big = CGSize(width: 200, height: 200)
        #expect(TerminalDirectionResolver.direction(for: CGPoint(x: 100, y: 100), in: big) == nil)
        #expect(TerminalDirectionResolver.direction(for: CGPoint(x: 100, y: 10), in: big) == .up)
        // 同一个落点，在小控件里是 down，在大控件里还在死区
        #expect(TerminalDirectionResolver.direction(for: CGPoint(x: 100, y: 105), in: big) == nil)
    }

    @Test("紧凑方向盘的对向箭头保持可辨识间距")
    func compactPadArrowsDoNotOverlap() {
        let contentSide = TerminalKeybarMetrics.compactPadSide
            - TerminalDirectionPadMetrics.contentInset * 2
        let edge = TerminalDirectionPadMetrics.edgeOffset(for: contentSide)
        let gap = contentSide - edge * 2 - TerminalDirectionPadMetrics.glyphFrame

        #expect(gap >= 4)
    }

    @Test("展开面板与 provider 按钮使用独立的内容和触控尺寸")
    func expandedProviderActionMetricsPreventClipping() {
        #expect(TerminalKeybarMetrics.expandedHeight == 284)
        #expect(TerminalKeybarMetrics.compactPadSide == 34)
        #expect(TerminalKeybarMetrics.directionPadTrailingInset == 8)
        #expect(TerminalKeybarMetrics.providerIconSize == 12)
        #expect(TerminalKeybarMetrics.providerLabelSize == 10)
        #expect(TerminalKeybarMetrics.providerContentHorizontalPadding == 4)
        #expect(TerminalKeybarMetrics.providerContentVerticalPadding == 2)
        #expect(
            TerminalKeybarMetrics.providerIconSize
                + TerminalKeybarMetrics.providerLabelSize
                + TerminalKeybarMetrics.providerContentSpacing
                + TerminalKeybarMetrics.providerContentVerticalPadding * 2
                <= TerminalKeybarMetrics.capVisualHeight
        )
        #expect(TerminalKeybarMetrics.hitTargetHeight == 44)
    }

    @Test("紧凑快捷键缩小后仍保留足够的方向箭头间距")
    func compactMetricsMakeRoomForTheHorizontalKeyScroll() {
        #expect(TerminalKeybarMetrics.compactCapWidth == 34)
        #expect(TerminalKeybarMetrics.capVisualHeight == 28)
        #expect(TerminalKeybarMetrics.compactPadSide == 34)
    }
}
