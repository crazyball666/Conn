import CoreGraphics

enum TerminalDirectionPadMetrics {
    static let contentInset: CGFloat = 4
    static let glyphFrame: CGFloat = 14
    static let glyphSize: CGFloat = 11
    static let centerDot: CGFloat = 3

    /// 箭头中心相对边缘的距离。按比例定位，并至少给 glyph 留出完整边界。
    static func edgeOffset(for side: CGFloat) -> CGFloat {
        let minimum = glyphFrame / 2 + 1
        let maximum = side / 2 - glyphFrame / 2 - 2
        return min(max(minimum, side * 0.22), maximum)
    }
}

/// 摇杆的落点 → 方向判定。
///
/// **刻意放在平台守卫之外**：摇杆视图本身依赖 UIKit，而 `swift test` 跑在 macOS 上，
/// 若把这段一起关进 `#if canImport(UIKit)`，它就永远没有测试覆盖——这正是摇杆的
/// 全部逻辑所在，其余只是手势与计时器。
enum TerminalDirectionResolver {
    /// 落点 → 方向。中心留死区，避免手指停在正中时来回抖。
    ///
    /// - Parameters:
    ///   - point: 触点在控件坐标系内的位置。
    ///   - size: 控件尺寸。判定按比例算，不写死边长。
    ///   - deadZone: 中心不响应的半径。
    static func direction(
        for point: CGPoint,
        in size: CGSize,
        deadZone: CGFloat = 10
    ) -> TerminalKey? {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        guard hypot(dx, dy) >= deadZone else { return nil }
        // 按 |dx| 与 |dy| 谁大分四象限：对角线上不产生歧义，各占 90°。
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .down : .up
    }
}

#if canImport(UIKit)
    import ConnUI
    import SwiftUI

    /// 方向摇杆：一个方块替掉原来四个方向键帽。
    ///
    /// **为什么按落点而不是按拖动位移判方向**：位移语义要求用户先按下再拖出去，
    /// 轻点方块上沿不会有任何反应，与「这是个十字键」的直觉相悖。改用触点相对
    /// 中心的方位后，轻点上沿即上、按住往左滑即左，点与拖是同一套判据。
    ///
    /// 长按连发的节奏取自 iOS 系统按键重复（先 400ms 停顿再每 100ms 一次），
    /// 手感与系统键盘一致，不用另造一套。
    struct TerminalDirectionPad: View {
        let onKey: (TerminalKey) -> Void

        /// 当前方向。`nil` 表示手指在死区里或已抬起。
        @State private var active: TerminalKey?
        /// 每发出一次方向自增。触感只认「值变了」，用计数器才能让连发每次都震。
        @State private var stepCount = 0
        @State private var repeatTask: Task<Void, Never>?

        /// 首次连发前的停顿。与 iOS 系统按键重复一致。
        private static let repeatDelay = Duration.milliseconds(400)
        /// 连发间隔。
        private static let repeatInterval = Duration.milliseconds(100)

        var body: some View {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                        .fill(Color.connKey)
                        .overlay(
                            RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                                .strokeBorder(Color.connKeyline, lineWidth: 1)
                        )
                    arrows
                }
                .contentShape(Rectangle())
                .gesture(gesture(in: geometry.size))
            }
            // 四个方向键合并成一个手势控件后，VoiceOver 用户就拖不出方向了，
            // 所以补四个具名动作把它们还回去。
            //
            // 标签与动作名直接用箭头字符：它们语言中立，VoiceOver 会按系统语言
            // 念成「向上箭头」等，无需给 ConnTerminal 另建一套字符串目录。
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "↑ ↓ ← →"))
            .accessibilityIdentifier("terminal.keybar.directionPad")
            .accessibilityAction(named: Text(verbatim: "↑")) { onKey(.up) }
            .accessibilityAction(named: Text(verbatim: "↓")) { onKey(.down) }
            .accessibilityAction(named: Text(verbatim: "←")) { onKey(.left) }
            .accessibilityAction(named: Text(verbatim: "→")) { onKey(.right) }
            .sensoryFeedback(ConnHapticFeedback.highImpact, trigger: stepCount)
            .onDisappear { stopRepeat() }
        }

        /// 四个方向的箭头，当前方向高亮。
        private var arrows: some View {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let edge = TerminalDirectionPadMetrics.edgeOffset(
                    for: min(geometry.size.width, geometry.size.height)
                )

                arrow(.up).position(x: center.x, y: edge)
                arrow(.down).position(x: center.x, y: geometry.size.height - edge)
                arrow(.left).position(x: edge, y: center.y)
                arrow(.right).position(x: geometry.size.width - edge, y: center.y)

                Circle()
                    .fill(Color.connLine)
                    .frame(
                        width: TerminalDirectionPadMetrics.centerDot,
                        height: TerminalDirectionPadMetrics.centerDot
                    )
                    .position(center)
            }
            .padding(TerminalDirectionPadMetrics.contentInset)
        }

        private func arrow(_ key: TerminalKey) -> some View {
            Image(systemName: symbolName(for: key))
                .font(.system(size: TerminalDirectionPadMetrics.glyphSize, weight: .semibold))
                .foregroundStyle(active == key ? Color.connAccent : .connMuted)
                .frame(
                    width: TerminalDirectionPadMetrics.glyphFrame,
                    height: TerminalDirectionPadMetrics.glyphFrame
                )
        }

        private func symbolName(for key: TerminalKey) -> String {
            switch key {
            case .up: "chevron.up"
            case .down: "chevron.down"
            case .left: "chevron.left"
            case .right: "chevron.right"
            default: "circle"
            }
        }

        private func gesture(in size: CGSize) -> some Gesture {
            // minimumDistance 0：轻点也要立即出方向，不要求先拖出一段距离。
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let direction = TerminalDirectionResolver.direction(for: value.location, in: size)
                    guard direction != active else { return }
                    active = direction
                    if let direction {
                        // 方向一确定就先发一次，连发是之后的事——这样单击也有效。
                        emit(direction)
                        startRepeat()
                    } else {
                        stopRepeat()
                    }
                }
                .onEnded { _ in
                    active = nil
                    stopRepeat()
                }
        }

        private func emit(_ key: TerminalKey) {
            stepCount &+= 1
            onKey(key)
        }

        private func startRepeat() {
            repeatTask?.cancel()
            repeatTask = Task { @MainActor in
                try? await Task.sleep(for: Self.repeatDelay)
                while !Task.isCancelled {
                    // 读的是**当前**方向：拖动中途改方向，连发跟着改，不用松手重按。
                    guard let direction = active else { return }
                    emit(direction)
                    try? await Task.sleep(for: Self.repeatInterval)
                }
            }
        }

        private func stopRepeat() {
            repeatTask?.cancel()
            repeatTask = nil
        }
    }
#endif
