import Foundation
import SwiftUI

/// 「回前台要不要恢复采集、在后台闲置了多久」的判定。
///
/// 从 `RootTabView` 的 `.onChange(of: scenePhase)` 里抽出来——内联在 View 里
/// 时这段逻辑无法单测，而它是整条「回前台重连」链路的入口：把 `.inactive`
/// （下拉通知中心、来电、任务切换器）误当成后台，或漏清 `backgroundedAt`
/// 导致每次回前台都重连，都不会有任何测试报警。
///
/// **不含阈值判定**：「闲置多久才值得驱逐会话」由
/// `MonitorScheduler.resumeAfterBackground(idleFor:)` 决定并已有测试覆盖。
/// 本类型只回答「要不要调它、传多少秒」，避免同一条规则落在两处各判一次。
struct BackgroundResumePolicy {
    /// 时间来源。可注入以便测试推进假时钟，而不必真的等待。
    private let now: () -> Date
    /// 进入后台的时刻；nil 表示「当前这次进前台之前没真进过后台」。
    private var backgroundedAt: Date?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 处理一次场景阶段变化。
    ///
    /// - Returns: 需要恢复时返回后台闲置秒数；不需要恢复返回 nil。
    mutating func idleDurationOnResume(for phase: ScenePhase) -> TimeInterval? {
        switch phase {
        case .background:
            // 不在这里 stop()：iOS 本就挂起 App，轮询 Task 自然停止推进，没有额外
            // 耗电；而回前台不保证重新触发 onAppear，停了就再也起不来。
            backgroundedAt = now()
            return nil
        case .active:
            // 冷启动首次进入前台、以及 `.inactive → .active` 的回摆都会走到这里，
            // 此时没有后台时刻，什么也不做。
            guard let backgroundedAt else { return nil }
            self.backgroundedAt = nil
            return now().timeIntervalSince(backgroundedAt)
        default:
            // `.inactive` 只是短暂失焦（通知中心、来电、任务切换器），App 仍在前台。
            // **必须原样保留 `backgroundedAt`**：真正回前台的系统事件序列是
            // `.background → .inactive → .active`，在这里清掉会让恢复永远不发生。
            return nil
        }
    }
}
