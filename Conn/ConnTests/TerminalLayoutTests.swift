import CoreGraphics
import SwiftTerm
import Testing
import UIKit
@testable import ConnTerminal

@Suite("KeybarTerminalView — 内容边距")
@MainActor
struct TerminalLayoutTests {
    @Test("关闭 SwiftTerm 自带输入附件，避免与自定义快捷键栏重复")
    func builtInAccessoryIsDisabled() {
        let view = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        #expect(view.inputAccessoryView == nil)
    }

    @Test("水平留白属于终端内部，并从可用列宽中扣除")
    func horizontalContentPaddingKeepsFullViewWidth() {
        let width: CGFloat = 320
        let padding: CGFloat = 12
        let view = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: width, height: 480))
        let unpaddedColumns = view.getTerminal().cols

        view.configureContentPadding(horizontal: padding)
        view.layoutIfNeeded()

        #expect(view.bounds.width == width)
        #expect(view.contentInset.left == padding)
        #expect(view.contentInset.right == padding)
        #expect(view.contentOffset.x == -padding)
        #expect(view.getTerminal().cols < unpaddedColumns)
    }

    @Test("终端纵向不注入额外 inset，键盘避让交给真实可见视口")
    func verticalInsetsStayEmpty() {
        let view = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        view.configureContentPadding(horizontal: 12)

        #expect(view.contentInsetAdjustmentBehavior == .never)
        #expect(view.contentInset.top == 0)
        #expect(view.contentInset.bottom == 0)
        #expect(view.verticalScrollIndicatorInsets.top == 0)
        #expect(view.verticalScrollIndicatorInsets.bottom == 0)
    }

    @Test("短内容从可见视口顶部开始，不被空白推到快捷键栏上方")
    func shortContentStaysTopAligned() {
        let view = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.resize(cols: 40, rows: 20)

        view.feedFollowingLiveOutput(byteArray: ArraySlice("demo-host:~$ ".utf8))
        view.layoutIfNeeded()

        #expect(view.contentInset.top == 0)
        #expect(view.contentInset.bottom == 0)
        #expect(view.contentOffset.y == 0)
        #expect(view.isScrollEnabled)
    }

    @Test("已有滚动历史时保持 SwiftTerm 原生滚动")
    func scrollbackKeepsNativeScrolling() {
        let view = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        view.resize(cols: 40, rows: 4)
        view.feedFollowingLiveOutput(
            byteArray: ArraySlice("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n".utf8)
        )
        #expect(view.canScroll)

        view.scroll(toPosition: 0)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(view.contentInset.top == 0)
        #expect(view.isScrollEnabled)
    }

    @Test("新输出自动跟随底部，用户上翻后保留阅读位置")
    func outputFollowsBottomUnlessUserScrolledBack() {
        let view = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        view.resize(cols: 40, rows: 4)

        view.feedFollowingLiveOutput(
            byteArray: ArraySlice("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n".utf8)
        )
        #expect(view.scrollPosition == 1)

        view.scroll(toPosition: 0)
        view.feedFollowingLiveOutput(byteArray: ArraySlice("9\r\n10\r\n".utf8))

        #expect(view.scrollPosition < 1)
    }
}
