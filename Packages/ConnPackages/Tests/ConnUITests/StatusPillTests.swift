import Foundation
import Testing
@testable import ConnUI

@Suite("StatusPill — 忙碌指示")
struct StatusPillTests {
    @Test("常规动效下画转圈，不用静态符号")
    func spinsWhenMotionAllowed() {
        #expect(StatusPill.busySymbol(reduceMotion: false) == nil)
    }

    /// 设计规范 §2：色彩不是唯一指示。关掉动效后必须仍有形状编码。
    @Test("reduceMotion 下退化为静态符号")
    func staticSymbolWhenMotionReduced() {
        #expect(StatusPill.busySymbol(reduceMotion: true) == "◌")
    }
}
