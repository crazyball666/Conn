import Foundation
import Testing
@testable import ConnUI

/// `ConnLoadBar` 的归一化纯函数：把调用方传入的原始百分比（可能越界、可能缺失）
/// clamp 到 `[0, 1]`。这段逻辑此前在四处调用点各写了一份 `min(max(x / 100, 0), 1)`，
/// 收进组件内部后只此一份，脱离 SwiftUI 单测，避免重新散开时悄悄漂移。
@Suite("ConnLoadBar — 百分比归一化")
struct ConnLoadBarTests {
    @Test("nil 保持 nil：无数据不画彩色头部")
    func nilStaysNil() {
        #expect(ConnLoadBar.fraction(ofPercent: nil) == nil)
    }

    @Test("0% 归一化为 0")
    func zeroPercent() {
        #expect(ConnLoadBar.fraction(ofPercent: 0) == 0)
    }

    @Test("50% 归一化为 0.5")
    func halfPercent() {
        #expect(ConnLoadBar.fraction(ofPercent: 50) == 0.5)
    }

    @Test("100% 归一化为 1")
    func fullPercent() {
        #expect(ConnLoadBar.fraction(ofPercent: 100) == 1)
    }

    @Test("负值 clamp 到 0（-5 → 0）")
    func belowRangeClampsToZero() {
        #expect(ConnLoadBar.fraction(ofPercent: -5) == 0)
    }

    @Test("超 100 clamp 到 1（130 → 1）")
    func aboveRangeClampsToOne() {
        #expect(ConnLoadBar.fraction(ofPercent: 130) == 1)
    }
}
