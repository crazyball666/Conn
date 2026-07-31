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
        window?.endEditing(true)
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
                touchLocationInActiveInput: activeInputView.map { touch.location(in: $0) }
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
        touchLocationInActiveInput: CGPoint? = nil
    ) -> Bool {
        // SwiftUI/UIKit 的覆盖视图有时会成为 `touch.view`，它不一定挂在真正的
        // 输入控件下面。因此先用当前第一响应者的真实坐标判断：点仍在终端内容
        // 范围内时，不允许全局手势触发 `endEditing(true)`。
        if let activeInputView,
           activeInputView is any UIKeyInput,
           let touchLocationInActiveInput,
           activeInputView.bounds.contains(touchLocationInActiveInput) {
            return false
        }

        var view = touchedView
        while let node = view {
            if node is any UIKeyInput { return false }
            view = node.superview
        }
        return true
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
