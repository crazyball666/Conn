import CoreGraphics
import SwiftTerm
import Testing
import UIKit
@testable import ConnTerminal

@Suite("KeybarTerminalView — 内容边距")
@MainActor
struct TerminalLayoutTests {
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
}
