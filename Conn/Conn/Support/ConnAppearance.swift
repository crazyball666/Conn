import UIKit

/// 全局 UIKit 外观微调（一次性）。
enum ConnAppearance {
    private static var configured = false

    static func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        configureSegmentedControl()
        configureSearchField()
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

    /// `.searchable` 的搜索框默认是浅灰填充，聚焦后又变白——切换很突兀。
    /// 直接把未聚焦态也设为「聚焦色」（浅色=白，深色=次级背景），聚焦时不再跳色。
    /// 两条 appearance 路径都设（UISearchTextField 直接 + UISearchBar 内含的 UITextField），
    /// 提高在不同 iOS/设备上的命中率。
    private static func configureSearchField() {
        let focused = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .white
        }
        UISearchTextField.appearance().backgroundColor = focused
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).backgroundColor = focused
    }
}
