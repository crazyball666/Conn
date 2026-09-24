import ConnUI
import SwiftUI
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

/// 恢复并遵循 App 全局外观模式（用于终端等局部强制深色主题的容器弹出子界面/模态弹窗时，彻底消除深色污染）。
struct RestoreAppAppearanceModifier: ViewModifier {
    let appearance: AppAppearance

    init(appearance: AppAppearance) {
        self.appearance = appearance
    }

    func body(content: Content) -> some View {
        let scheme = appearance.effectiveColorScheme
        content
            .background(Color.connBg.ignoresSafeArea())
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
    }
}

extension View {
    /// 强制当前视图脱离局部主题覆盖，恢复为 App 全局外观模式（包含对“跟随系统”当前真实状态的动态解析与安全背景色）。
    func restoreAppAppearance(_ appearance: AppAppearance) -> some View {
        modifier(RestoreAppAppearanceModifier(appearance: appearance))
    }
}
