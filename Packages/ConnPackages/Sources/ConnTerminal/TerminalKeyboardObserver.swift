#if canImport(UIKit)
import Combine
import SwiftUI
import UIKit

/// 监听系统键盘高度及动画状态，为快捷键面板的展开提供与键盘高度无缝对齐的动力学支持。
@MainActor
public final class TerminalKeyboardObserver: ObservableObject {
    public static let shared = TerminalKeyboardObserver()

    /// 当前键盘在屏幕内占据的高度（0 表示隐藏）
    @Published public private(set) var currentKeyboardHeight: CGFloat = 0

    /// 最近一次测得的有效键盘高度（即使键盘隐藏后依然保持），用于展开快捷键面板时对齐
    @Published public private(set) var lastKnownKeyboardHeight: CGFloat

    /// 键盘是否处于显示状态
    @Published public private(set) var isKeyboardVisible: Bool = false

    /// 键盘当前/最近一次动画时长（默认 0.25 秒）
    @Published public private(set) var animationDuration: TimeInterval = 0.25

    private var cancellables = Set<AnyCancellable>()

    public init() {
        let screen = UIScreen.main.bounds
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let defaultHeight: CGFloat = isPad ? 320 : (screen.height > 800 ? 336 : 260)
        _lastKnownKeyboardHeight = Published(initialValue: defaultHeight)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .compactMap { $0.userInfo }
            .sink { [weak self] userInfo in
                self?.handleKeyboardFrameChange(userInfo: userInfo)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .compactMap { $0.userInfo }
            .sink { [weak self] userInfo in
                guard let self else { return }
                if let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
                   duration > 0 {
                    self.animationDuration = duration
                }
                withAnimation(.easeInOut(duration: self.animationDuration)) {
                    self.currentKeyboardHeight = 0
                    self.isKeyboardVisible = false
                }
            }
            .store(in: &cancellables)
    }

    private func handleKeyboardFrameChange(userInfo: [AnyHashable: Any]) {
        if let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
           duration > 0 {
            self.animationDuration = duration
        }
        guard let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        let screenHeight = UIScreen.main.bounds.height
        let height = max(0, screenHeight - endFrame.minY)

        if height > 50 {
            withAnimation(.easeInOut(duration: self.animationDuration)) {
                self.currentKeyboardHeight = height
                self.lastKnownKeyboardHeight = height
                self.isKeyboardVisible = true
            }
        } else {
            withAnimation(.easeInOut(duration: self.animationDuration)) {
                self.currentKeyboardHeight = 0
                self.isKeyboardVisible = false
            }
        }
    }

    /// 获取当前有效 window 的底部安全区高度
    public var safeAreaBottom: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        return window?.safeAreaInsets.bottom ?? 0
    }

    #if DEBUG
    /// 测试环境注入预设高度与动画
    public func updateForTesting(height: CGFloat, animationDuration: TimeInterval = 0.25) {
        if height > 50 {
            self.currentKeyboardHeight = height
            self.lastKnownKeyboardHeight = height
            self.isKeyboardVisible = true
        } else {
            self.currentKeyboardHeight = 0
            self.isKeyboardVisible = false
        }
        self.animationDuration = animationDuration
    }
    #endif
}
#endif
