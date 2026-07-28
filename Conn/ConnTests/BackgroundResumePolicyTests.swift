import Foundation
import SwiftUI
import Testing
@testable import Conn

/// 覆盖 `RootTabView` 的前后台接线：这段判定原本内联在 View 的
/// `.onChange(of: scenePhase)` 里，测不到——把 `.inactive` 也当成后台、
/// 或漏清后台时刻，都不会有任何测试报警。
@MainActor
@Suite("BackgroundResumePolicy — 回前台恢复判定")
struct BackgroundResumePolicyTests {
    /// 手动推进的假时钟。时间来源可注入，测试无需真的等待墙钟。
    private final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    private func makePolicy(clock: FakeClock) -> BackgroundResumePolicy {
        BackgroundResumePolicy(now: { clock.now })
    }

    @Test("冷启动首次进入前台（从没进过后台）：不触发恢复")
    func coldStartDoesNotResume() {
        var policy = makePolicy(clock: FakeClock())

        #expect(policy.idleDurationOnResume(for: .active) == nil)
    }

    /// 下拉通知中心、来电、任务切换器都只让 App 短暂失焦（`.inactive`），
    /// App 并未真正进入后台——SSH 连接还活着，不该驱逐重连。
    @Test("active → inactive → active（没真进后台）：不触发恢复")
    func inactiveRoundTripDoesNotResume() {
        let clock = FakeClock()
        var policy = makePolicy(clock: clock)

        #expect(policy.idleDurationOnResume(for: .active) == nil)
        clock.advance(120)
        #expect(policy.idleDurationOnResume(for: .inactive) == nil)
        clock.advance(120)
        #expect(policy.idleDurationOnResume(for: .active) == nil)
    }

    @Test("active → background →（10 秒）→ active：触发恢复，闲置时长为 10")
    func resumesWithMeasuredIdleDuration() {
        let clock = FakeClock()
        var policy = makePolicy(clock: clock)

        #expect(policy.idleDurationOnResume(for: .background) == nil)
        clock.advance(10)

        #expect(policy.idleDurationOnResume(for: .active) == 10)
    }

    /// 真正回前台的系统事件序列是 `.background → .inactive → .active`。
    /// 若 `.inactive` 分支顺手清掉了后台时刻，恢复就永远不会发生——
    /// 这条锁住「`.inactive` 不许动状态」。
    @Test("background → inactive → active：中间的 inactive 不清状态，仍按后台时长恢复")
    func inactiveDoesNotClearBackgroundedAt() {
        let clock = FakeClock()
        var policy = makePolicy(clock: clock)

        #expect(policy.idleDurationOnResume(for: .background) == nil)
        clock.advance(45)
        #expect(policy.idleDurationOnResume(for: .inactive) == nil)

        #expect(policy.idleDurationOnResume(for: .active) == 45)
    }

    /// 连续两次 `.active`（第二次后台时刻已清）：只恢复一次。
    /// 漏清会让此后每次进前台都 `invalidateAll()`，把终端 / 日志流 / sftp
    /// 这些骑在同一条连接上的长命通道反复打死。
    @Test("连续两次 active：第二次不重复触发")
    func secondActiveDoesNotResumeAgain() {
        let clock = FakeClock()
        var policy = makePolicy(clock: clock)

        _ = policy.idleDurationOnResume(for: .background)
        clock.advance(60)
        #expect(policy.idleDurationOnResume(for: .active) == 60)

        clock.advance(60)
        #expect(policy.idleDurationOnResume(for: .active) == nil)
    }

    /// 阈值（>30s 才驱逐会话）留在 `MonitorScheduler.resumeAfterBackground(idleFor:)`，
    /// 本类型只如实报时长，短暂切走也照报——两处各判一次才是真正的隐患。
    @Test("短暂切到后台也照报时长，阈值判定不在本类型")
    func reportsShortIdleWithoutFiltering() {
        let clock = FakeClock()
        var policy = makePolicy(clock: clock)

        _ = policy.idleDurationOnResume(for: .background)
        clock.advance(2)

        #expect(policy.idleDurationOnResume(for: .active) == 2)
    }
}
