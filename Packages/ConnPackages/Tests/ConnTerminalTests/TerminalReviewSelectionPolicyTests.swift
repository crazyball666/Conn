import Foundation
import Testing
@testable import ConnTerminal

@Suite("TerminalReviewSelectionPolicy — 原生选词动作")
struct TerminalReviewSelectionPolicyTests {
    @Test("长按单词内部选择完整 UTF-16 单词")
    func selectsWholeWordAtUTF16Offset() {
        #expect(TerminalReviewSelectionPolicy.wordRange(
            in: "hello world",
            utf16Offset: 2
        ) == NSRange(location: 0, length: 5))
    }

    @Test("全选覆盖完整 UTF-16 文本")
    func selectAllCoversCompleteUTF16Text() {
        #expect(TerminalReviewSelectionPolicy.effect(
            for: .selectAll,
            text: "A😀中",
            selectedRange: NSRange(location: 0, length: 1)
        ) == .selection(NSRange(location: 0, length: 4)))
    }

    @Test("复制只返回当前选区并请求关闭 review")
    func copyReturnsSelectedTextAndDismisses() {
        #expect(TerminalReviewSelectionPolicy.effect(
            for: .copy,
            text: "hello world",
            selectedRange: NSRange(location: 6, length: 5)
        ) == .copy(text: "world", dismisses: true))
    }

    @Test("完成只关闭 review，不产生剪贴板内容")
    func doneDismissesWithoutClipboardEffect() {
        #expect(TerminalReviewSelectionPolicy.effect(
            for: .done,
            text: "secret",
            selectedRange: NSRange(location: 0, length: 6)
        ) == .dismiss)
    }

    @Test("越界选区不会产生复制内容")
    func invalidCopyRangeDoesNothing() {
        #expect(TerminalReviewSelectionPolicy.effect(
            for: .copy,
            text: "abc",
            selectedRange: NSRange(location: 99, length: 3)
        ) == .none)
    }
}
