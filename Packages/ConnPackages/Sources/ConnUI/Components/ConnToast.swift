import Observation
import SwiftUI

public enum ConnToastStyle: String, Sendable, Equatable, CaseIterable {
    case success
    case info
    case warning
    case error

    public var systemImageName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    public var autoDismissDuration: Duration {
        switch self {
        case .success, .info: .seconds(1.5)
        case .warning: .seconds(2.5)
        case .error: ConnToastTimer.autoDismissDuration
        }
    }
}

public struct ConnToastItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let message: String
    public let style: ConnToastStyle

    public init(
        id: UUID = UUID(),
        message: String,
        style: ConnToastStyle
    ) {
        self.id = id
        self.message = message
        self.style = style
    }
}

/// App 级 Toast 状态。所有页面共用同一个提示出口，避免错误提示被局限在
/// 当前页面的导航栈里，切换页面或打开表单时也能保持一致的交互。
@Observable
public final class ConnToastCenter {
    public var item: ConnToastItem?

    public init(item: ConnToastItem? = nil) {
        self.item = item
    }

    /// 每次发布都生成新的事件身份。即使连续提示文案相同，也会重新展示并计时。
    public func show(
        _ message: String?,
        style: ConnToastStyle = .error
    ) {
        guard let message else {
            item = nil
            return
        }
        item = ConnToastItem(message: message, style: style)
    }

    public func dismiss() {
        item = nil
    }
}

private struct ConnToastCenterKey: EnvironmentKey {
    static let defaultValue = ConnToastCenter()
}

public extension EnvironmentValues {
    var connToastCenter: ConnToastCenter {
        get { self[ConnToastCenterKey.self] }
        set { self[ConnToastCenterKey.self] = newValue }
    }
}

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
    let item: ConnToastItem
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ConnSpacing.xs) {
            Image(systemName: item.style.systemImageName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(item.message)
                .font(.connFootnote)
                .foregroundStyle(.connInk)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityLabel(item.message)
        .accessibilityIdentifier("conn.toast.\(item.style.rawValue)")
    }

    private var iconColor: Color {
        switch item.style {
        case .success: .connGood
        case .info: .connAccent
        case .warning: .connWarn
        case .error: .connCrit
        }
    }
}

private struct ConnToastModifier: ViewModifier {
    @Binding var item: ConnToastItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            if let item {
                ConnToast(item: item) { self.item = nil }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, ConnSpacing.page)
                    .padding(.top, ConnSpacing.sm)
                    .zIndex(1)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                    .task(id: item.id) {
                        if await ConnToastTimer.waitForAutoDismiss(
                            item.style.autoDismissDuration
                        ) {
                            guard self.item?.id == item.id else { return }
                            self.item = nil
                        }
                    }
            }
        }
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.18)
                : .spring(response: 0.34, dampingFraction: 0.86),
            value: item
        )
    }
}

private struct ConnGlobalToastModifier: ViewModifier {
    @Environment(\.connToastCenter) private var center

    func body(content: Content) -> some View {
        @Bindable var center = center
        return content.modifier(ConnToastModifier(item: $center.item))
    }
}

public extension View {
    /// 绑定一个带语义的提示事件。
    ///
    /// 挂在页面内容视图上（`NavigationStack` 内部），不要挂在 `NavigationStack` 外层。
    func connToast(item: Binding<ConnToastItem?>) -> some View {
        modifier(ConnToastModifier(item: item))
    }

    /// 使用 App 级 Toast 中心。应挂在根内容视图上，页面只需调用
    /// `EnvironmentValues.connToastCenter.show(_:)` 发布提示。
    func connGlobalToast() -> some View {
        modifier(ConnGlobalToastModifier())
    }
}
