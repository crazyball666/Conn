import UIKit

/// 全局「点击空白处收起键盘」。
///
/// 在 key window 上挂一个 `UITapGestureRecognizer`，任意点击都 `endEditing(true)`。
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
            var view = touch.view
            while let node = view {
                if node is UITextField || node is UITextView { return false }
                view = node.superview
            }
            return true
        }
    }
}
