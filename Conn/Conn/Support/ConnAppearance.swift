import UIKit

/// 全局 UIKit 外观微调（一次性）。
enum ConnAppearance {
    private static var configured = false

    static func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        configureSegmentedControl()
    }

    /// SwiftUI 的 `.pickerStyle(.segmented)` 底层是原生 `UISegmentedControl`（iOS 26 液态玻璃）。
    /// 只放大加粗标题（14pt semibold），不改样式/结构，保留原生观感。
    private static func configureSegmentedControl() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
        ]
        let appearance = UISegmentedControl.appearance()
        appearance.setTitleTextAttributes(attributes, for: .normal)
        appearance.setTitleTextAttributes(attributes, for: .selected)
    }
}
