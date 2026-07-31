import SwiftTerm
import Testing
import UIKit
@testable import Conn
@testable import ConnTerminal

@Suite("KeyboardDismisser — 输入控件识别")
@MainActor
struct KeyboardDismisserTests {
    @Test("点击 SwiftTerm 自定义输入视图时不触发全局收键盘")
    func terminalTapDoesNotDismissKeyboard() {
        let terminal = KeybarTerminalView(frame: .zero)

        #expect(!KeyboardDismisser.shouldDismissKeyboard(for: terminal))
    }

    @Test("触点视图不在终端层级内，但坐标位于当前终端时也不收键盘")
    func activeTerminalHitDoesNotDismissKeyboard() {
        let terminal = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let overlay = UIView()

        #expect(!KeyboardDismisser.shouldDismissKeyboard(
            for: overlay,
            activeInputView: terminal,
            touchLocationInActiveInput: CGPoint(x: 160, y: 240)
        ))
    }

    @Test("触点位于当前输入区域之外时仍然收键盘")
    func outsideActiveInputDismissesKeyboard() {
        let terminal = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let navigationContent = UIView()

        #expect(KeyboardDismisser.shouldDismissKeyboard(
            for: navigationContent,
            activeInputView: terminal,
            touchLocationInActiveInput: CGPoint(x: 160, y: -40)
        ))
    }

    @Test("点击普通空白仍然触发全局收键盘")
    func backgroundTapDismissesKeyboard() {
        #expect(KeyboardDismisser.shouldDismissKeyboard(for: UIView()))
    }

    @Test("点击文本输入控件的子视图也不触发全局收键盘")
    func textInputDescendantDoesNotDismissKeyboard() {
        let textField = UITextField()
        let child = UIView()
        textField.addSubview(child)

        #expect(!KeyboardDismisser.shouldDismissKeyboard(for: child))
    }
}
