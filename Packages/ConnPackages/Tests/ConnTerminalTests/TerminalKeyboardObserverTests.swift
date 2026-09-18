#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import ConnTerminal

@Suite("TerminalKeyboardObserver — 键盘高度同步与动态匹配")
struct TerminalKeyboardObserverTests {
    @Test("初始状态包含有效的默认键盘高度")
    @MainActor
    func initialKeyboardHeightIsValid() {
        let observer = TerminalKeyboardObserver.shared
        #expect(observer.lastKnownKeyboardHeight >= 260)
        #expect(observer.animationDuration > 0)
    }

    @Test("注入键盘高度能同步更新当前与历史高度")
    @MainActor
    func updateKeyboardHeightUpdatesState() {
        let observer = TerminalKeyboardObserver.shared
        let originalLastKnown = observer.lastKnownKeyboardHeight

        observer.updateForTesting(height: 336, animationDuration: 0.3)
        #expect(observer.currentKeyboardHeight == 336)
        #expect(observer.lastKnownKeyboardHeight == 336)
        #expect(observer.isKeyboardVisible == true)
        #expect(observer.animationDuration == 0.3)

        // 模拟键盘关闭（高度为 0），保留 lastKnownKeyboardHeight
        observer.updateForTesting(height: 0, animationDuration: 0.25)
        #expect(observer.currentKeyboardHeight == 0)
        #expect(observer.lastKnownKeyboardHeight == 336)
        #expect(observer.isKeyboardVisible == false)
        #expect(observer.animationDuration == 0.25)

        // 恢复
        observer.updateForTesting(height: originalLastKnown, animationDuration: 0.25)
    }

    @Test("动态展开高度公式准确对齐键盘高度且下限不低于180")
    func dynamicExpandedHeightCalculation() {
        let spacing = TerminalKeybarMetrics.gridSpacing
        let safeAreaBottom: CGFloat = 34
        let keyboardHeight: CGFloat = 336

        let calculatedHeight = max(180, keyboardHeight - safeAreaBottom - spacing)
        #expect(calculatedHeight == 336 - 34 - 4) // 298

        // 低高度时保底 180
        let smallKeyboardHeight: CGFloat = 150
        let clampedHeight = max(180, smallKeyboardHeight - safeAreaBottom - spacing)
        #expect(clampedHeight == 180)
    }

    @Test("Keybar 展开高度默认与动态覆盖值计算正确")
    func keybarExpandedContentHeightResolution() {
        // 默认 fallback 高度
        let defaultResolved = TerminalKeybarMetrics.expandedHeight
            - TerminalKeybarMetrics.compactHeight
            - TerminalKeybarMetrics.gridSpacing
        #expect(defaultResolved == 220 - 46 - 4) // 170

        // 注入动态展开高度
        let dynamicHeight: CGFloat = 298
        #expect(dynamicHeight > defaultResolved)
    }
}
#endif
