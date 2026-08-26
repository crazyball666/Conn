import ConnTerminal
import UIKit

/// 全局「点击空白处收起键盘」。
///
/// 在 key window 上挂一个 `UITapGestureRecognizer`，点击非输入区域时 `endEditing(true)`。
/// `cancelsTouchesInView = false` + 允许同时识别 → 不拦截按钮/列表等原有交互，
/// 只是顺带收起键盘。一次安装，全 App 生效（含表单、搜索框、编辑器等所有输入框）。
@MainActor
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()
    private var installed = false
    private weak var window: UIWindow?

    func installIfNeeded() {
        guard !installed else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        else { return }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        self.window = window
        installed = true
    }

    @objc private func handleTap() {
        // `shouldReceive` 发生在触摸开始阶段；同一次触摸可能随后弹出 Alert。
        // 等本轮触摸完整交付给 SwiftUI Button 后再收起键盘。如果在手势
        // callback 中同步 endEditing，iOS 26 的 List/Button 会只收键盘而丢掉
        // 本次 action，表现为“创建并连接/保存需要点两次”。
        guard let window else { return }
        let responderAtTouchEnd = Self.firstInputResponder(in: window)
        Self.afterCurrentTouchDelivery {
            // Button action 可能已弹出 Alert 或将焦点交给新输入框；这些情况
            // 不得被迟到的全局收键盘再次干扰。
            guard !Self.containsSystemAlert(in: window.rootViewController) else { return }
            guard Self.firstInputResponder(in: window) === responderAtTouchEnd else { return }
            window.endEditing(true)
        }
    }

    /// UIKit 的全局手势与 SwiftUI Button 共用同一次触摸时，必须让按钮先完成
    /// action 交付。保持为独立 seam，便于用单元测试锁定执行顺序。
    static func afterCurrentTouchDelivery(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            action()
        }
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// 触点落在文本输入控件（或其内部，含选择手柄）上时**不接管**——否则会打断长按选择、
    /// 复制/粘贴菜单、光标定位等系统文本交互。只在真正的空白处才收起键盘。
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        MainActor.assumeIsolated {
            let activeInputView = window.flatMap(Self.firstInputResponder(in:))
            return Self.shouldDismissKeyboard(
                for: touch.view,
                activeInputView: activeInputView,
                touchLocationInActiveInput: activeInputView.map { touch.location(in: $0) },
                systemAlertPresented: Self.containsSystemAlert(
                    in: window?.rootViewController
                )
            )
        }
    }

    /// `UITextField` / `UITextView` 之外还有 SwiftTerm 这类直接实现 `UIKeyInput`
    /// 的自定义输入控件。它们被点击时会在自己的手势中请求第一响应者；若全局手势
    /// 同时执行 `endEditing(true)`，同一次触摸会并发触发键盘显示与隐藏，导致 SwiftUI
    /// 键盘安全区在动画结束后残留错误高度。
    static func shouldDismissKeyboard(
        for touchedView: UIView?,
        activeInputView: UIView? = nil,
        touchLocationInActiveInput: CGPoint? = nil,
        systemAlertPresented: Bool = false
    ) -> Bool {
        // SwiftUI Alert 的按钮在不同系统版本上不一定暴露为 UIControl。
        // Alert 存在时完全停用全局收键盘，让系统自己管理输入框与 action 点击。
        if systemAlertPresented {
            return false
        }

        // SwiftUI/UIKit 的覆盖视图有时会成为 `touch.view`，它不一定挂在真正的
        // 输入控件下面。因此先用当前第一响应者的真实坐标判断：点仍在终端内容
        // 范围内时，不允许全局手势触发 `endEditing(true)`。
        if let activeInputView,
           activeInputView is any UIKeyInput,
           let touchLocationInActiveInput,
           activeInputView.bounds.contains(touchLocationInActiveInput) {
            return false
        }

        // 快捷键栏现在与终端视口同层，位于终端 bounds 的正下方。SwiftUI 的实际
        // touch.view 不一定保留 accessibilityIdentifier，因此同时按当前终端坐标
        // 保护这块区域，覆盖紧凑和展开两种高度。
        if let activeInputView,
           activeInputView.accessibilityIdentifier == "terminal.viewport",
           let point = touchLocationInActiveInput,
           activeInputView.bounds.minX ... activeInputView.bounds.maxX ~= point.x,
           activeInputView.bounds.minY ... (
               activeInputView.bounds.maxY + TerminalKeybarMetrics.expandedHeight
           ) ~= point.y {
            return false
        }

        var view = touchedView
        while let node = view {
            if node is any UIKeyInput {
                return false
            }
            // 按钮、开关以及系统 Alert action 都是 UIControl。全局收键盘手势若与
            // 它们同时调用 endEditing，会让 Alert 的第一次点击只收键盘而不提交。
            if node is UIControl {
                return false
            }
            // 终端快捷键栏是终端视口下面的独立 SwiftUI 区域，不属于 UIKeyInput。
            // 它的按钮必须保持当前终端为第一响应者，否则全局空白点击手势会先
            // 收起键盘，再让展开/方向/Ctrl 等快捷操作失效。
            if node.accessibilityIdentifier?.hasPrefix("terminal.keybar") == true {
                return false
            }
            view = node.superview
        }
        return true
    }

    static func containsSystemAlert(in viewController: UIViewController?) -> Bool {
        guard let viewController else { return false }
        if viewController is UIAlertController {
            return true
        }
        if containsSystemAlert(in: viewController.presentedViewController) {
            return true
        }
        return viewController.children.contains(where: { containsSystemAlert(in: $0) })
    }

    private static func firstInputResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder, view is any UIKeyInput {
            return view
        }
        for subview in view.subviews {
            if let responder = firstInputResponder(in: subview) {
                return responder
            }
        }
        return nil
    }
}
