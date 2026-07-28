import SwiftUI

/// Toast 的自动消失计时。抽成独立类型以便脱离 SwiftUI 单测。
public enum ConnToastTimer {
    /// 默认停留时长。
    public static let autoDismissDuration: Duration = .seconds(3.5)

    /// 等待自动消失。
    ///
    /// - Returns: 正常等到时长结束返回 `true`（应清空消息）；
    ///   被取消（例如新消息顶掉旧消息）返回 `false`。
    public static func waitForAutoDismiss(
        _ duration: Duration = autoDismissDuration
    ) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }
}

/// 顶部浮层提示条。
///
/// 挂在**页面内容视图**上（`NavigationStack` 内部），因此天然落在导航栏下方、
/// 不与大标题重叠。点击或上滑可提前关闭。
struct ConnToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: ConnSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.connCrit)
            Text(message)
                .font(.connFootnote)
                .foregroundStyle(.connInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.vertical, ConnSpacing.xs)
        .connSurface(cornerRadius: ConnRadius.control)
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < 0 { onDismiss() }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct ConnToastModifier: ViewModifier {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    ConnToast(message: message) { self.message = nil }
                        .padding(.horizontal, ConnSpacing.page)
                        .padding(.top, ConnSpacing.sm)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity)
                        )
                        // id 绑到消息内容：后到的消息顶掉前一条并重置计时器，不排队叠加。
                        .task(id: message) {
                            if await ConnToastTimer.waitForAutoDismiss() {
                                self.message = nil
                            }
                        }
                }
            }
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.18)
                    : .spring(response: 0.34, dampingFraction: 0.86),
                value: message
            )
    }
}

public extension View {
    /// 绑定一段可空提示文案：非 nil 即从导航栏下方滑入，3.5s 后自动清空。
    ///
    /// 挂在页面内容视图上（`NavigationStack` 内部），不要挂在 `NavigationStack` 外层。
    func connToast(message: Binding<String?>) -> some View {
        modifier(ConnToastModifier(message: message))
    }
}
