import SwiftUI

/// 动效令牌。
///
/// 设计规范 §6 铁律：**频率决定是否动画**——高频操作（键盘触发、会话切换）
/// 不动画；常规弹层标准动画；首次/低频场景可加仪式感。
///
/// **动效白名单**（除此以外不动）：状态点脉冲、指标环首次绘制、下拉刷新、
/// 粘滞键点亮、按压反馈、弹层进出场。禁止视差、明显弹跳、装饰性粒子。
public enum ConnMotion {
    /// 按压反馈时长。100–160ms 区间取中。
    public static let pressDuration: Double = 0.13
    /// 按压缩放比。规范 §6 定 0.97（§5 的 ActionTile 写 0.96，以 §6 为准统一）。
    public static let pressScale: CGFloat = 0.97

    /// 进场：强 ease-out。**永不从 scale(0) 出现**，起点 ≥ 0.96。
    public static let enter: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    /// 退场：一律快于进场（约 0.7×）。
    public static let exit: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    /// Sheet / 抽屉：iOS drawer 曲线，可中断。
    public static let sheet: Animation = .spring(duration: 0.4, bounce: 0.1)
    /// 状态点故障脉冲周期。
    public static let pulsePeriod: Double = 1.2
}

/// 全局按压反馈样式：`scale(0.97)`，约 130ms ease-out。
///
/// 设计规范 §6：「所有可按元素」——界面在听你说话。
/// 尊重 `accessibilityReduceMotion`：开启时保留透明度变化、去除缩放位移。
public struct ConnPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scale(for: configuration.isPressed))
            .opacity(configuration.isPressed ? 0.92 : 1)
            // 弹簧回弹比线性 easeOut 更「活」——按下即缩、松开带一丝回弹,像真实按键。
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }

    private func scale(for pressed: Bool) -> CGFloat {
        guard pressed else { return 1 }
        return reduceMotion ? 1 : ConnMotion.pressScale
    }
}
