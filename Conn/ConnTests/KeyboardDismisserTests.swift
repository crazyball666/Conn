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

    @Test("全局收键盘延后到 SwiftUI 按钮 action 交付之后")
    func dismissalRunsAfterCurrentTouchDelivery() async {
        var events = ["gesture"]

        await withCheckedContinuation { continuation in
            KeyboardDismisser.afterCurrentTouchDelivery {
                events.append("dismiss")
                continuation.resume()
            }
            events.append("button-action")
        }

        #expect(events == ["gesture", "button-action", "dismiss"])
    }

    @Test("点击 Alert 保存按钮等 UIControl 不触发全局收键盘")
    func controlTapDoesNotDismissKeyboard() {
        let button = UIButton(type: .system)
        let label = UILabel()
        button.addSubview(label)

        #expect(!KeyboardDismisser.shouldDismissKeyboard(for: button))
        #expect(!KeyboardDismisser.shouldDismissKeyboard(for: label))
    }

    @Test("系统 Alert 显示期间普通 SwiftUI 渲染视图也不能触发收键盘")
    func systemAlertBlocksGlobalKeyboardDismissal() {
        #expect(!KeyboardDismisser.shouldDismissKeyboard(
            for: UIView(),
            systemAlertPresented: true
        ))
    }

    @Test("可以从控制器层级识别系统 Alert")
    func detectsSystemAlertController() {
        let alert = UIAlertController(
            title: "重命名 Session",
            message: nil,
            preferredStyle: .alert
        )

        #expect(KeyboardDismisser.containsSystemAlert(in: alert))
        #expect(!KeyboardDismisser.containsSystemAlert(in: UIViewController()))
    }

    @Test("点击文本输入控件的子视图也不触发全局收键盘")
    func textInputDescendantDoesNotDismissKeyboard() {
        let textField = UITextField()
        let child = UIView()
        textField.addSubview(child)

        #expect(!KeyboardDismisser.shouldDismissKeyboard(for: child))
    }

    @Test("点击终端快捷键栏不会触发全局收键盘")
    func terminalKeybarTapDoesNotDismissKeyboard() {
        let keybar = UIView()
        keybar.accessibilityIdentifier = "terminal.keybar"
        let buttonContent = UIView()
        keybar.addSubview(buttonContent)

        #expect(!KeyboardDismisser.shouldDismissKeyboard(for: buttonContent))
    }

    @Test("SwiftUI 触点视图无法识别时，终端下方快捷键区域仍不收键盘")
    func terminalKeybarCoordinatesDoNotDismissKeyboard() {
        let terminal = KeybarTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        terminal.accessibilityIdentifier = "terminal.viewport"
        let swiftUIRenderView = UIView()

        #expect(!KeyboardDismisser.shouldDismissKeyboard(
            for: swiftUIRenderView,
            activeInputView: terminal,
            touchLocationInActiveInput: CGPoint(x: 160, y: 526)
        ))
    }
}
