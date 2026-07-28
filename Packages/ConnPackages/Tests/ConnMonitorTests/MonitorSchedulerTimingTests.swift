import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

/// 采集时机收敛（预热轮 / 防抖 / 回前台恢复）与并发收敛（代次）。
///
/// 与「采集阶段与重试」拆成两个文件，共用 `MonitorSchedulerTestSupport` 里的假引擎。
@MainActor
@Suite("MonitorScheduler — 采集时机与并发收敛")
struct MonitorSchedulerTimingTests {
    private func host(_ id: String = "h1", address: String = "10.0.0.1") -> DomainHost {
        makeHost(id, address: address)
    }

    // MARK: - 预热轮与防抖

    @Test("已有读数时跳过 2s 预热轮")
    func skipsWarmUpWhenBaselineExists() async throws {
        // 用可控时钟并把「上次采集」推到 5s 防抖窗口之外：
        // 若沿用默认真实时钟，scanNow 与紧随其后的 startDashboard 之间只隔几毫秒，
        // 会意外触发防抖（isFresh），连「立即那一轮」也被跳过，
        // 这条测试就测不到「预热轮」这一个变量了。
        let clock = MutableClock()
        let (scheduler, log) = makeScheduler(now: { clock.now })
        let target = host()
        await scheduler.scanNow(hosts: [target])       // exec 1，建立基线
        let before = await log.execs

        clock.advance(by: 10)                          // 越过防抖窗口，只考察预热轮
        scheduler.startDashboard(hosts: [target], interval: .seconds(600))

        // 先用因果等待确认「立即那一轮」已经落地，避免把它和后面的定长等待混在一起。
        await waitUntilExecCount(log, atLeast: before + 1)

        // 预热轮的第二次采集绑的是生产代码里真实的 `Task.sleep(for: .seconds(2))`，
        // 不受注入的 MutableClock 影响（MutableClock 只影响 `now()`，不影响
        // Task.sleep 的墙钟）。这里要断言的是「它不应该发生」——不存在的事件
        // 没有因果信号可等，只能真等过 2s 这个临界点（留到 2.3s 的余量）再看结果。
        // 这也是原测试的缺陷所在：原来只等 300ms 就 stop()，预热轮的第二次采集
        // 还睡在那 2s 里没醒来就被取消，于是无论 needsWarmUp 取何值，
        // 观察窗口内 execs 都只多 1，断言恒真、测不出错误。
        try await Task.sleep(for: .milliseconds(2300))
        scheduler.stop()

        // 只应多出「立即那一轮」，不该有 2s 后的预热轮
        #expect(await log.execs == before + 1)
    }

    @Test("无基线时预热轮确实触发：立即一轮 + 2s 后再一轮")
    func warmUpRunsWhenNoBaselineExists() async throws {
        // 反向覆盖：上一条测试只验证「有基线 → 跳过预热轮」，两次变异
        // （needsWarmUp 恒 true / 恒 false）对全部既有用例都不可见的原因之一，
        // 就是没有任何测试断言过「预热轮真的会触发」这条路径。
        //
        // 全新 scheduler，metrics 为空、lastScanAt 为 nil：
        //   isFresh = !force && !needsWarmUp && (lastScanAt.map { ... } ?? false)
        // 三个合取项都为假，不需要 MutableClock 介入。
        let (scheduler, log) = makeScheduler()
        let target = host()

        scheduler.startDashboard(hosts: [target], interval: .seconds(600))

        // 立即那一轮：因果等待，默认 pollInterval（Task.yield）即可，几乎瞬间完成。
        await waitUntilExecCount(log, atLeast: 1)
        #expect(await log.execs == 1)

        // 预热轮的第二次采集绑的是真实 2s 的 Task.sleep。这里断言的是「它会发生」，
        // 是可以因果等待的正向事件，所以不用定长 sleep 赌一个时长，而是传入非零
        // pollInterval 让轮询真的睡过这段墙钟时间，事件一落地（execs 到 2）立刻返回；
        // 上限给到 3s（60 次 * 50ms）留出余量。若 needsWarmUp 被错误地恒为 false，
        // 第二轮永远不会发生，等到耗尽上限后 execs 仍停在 1，下面的断言会如实失败。
        await waitUntilExecCount(log, atLeast: 2, maxAttempts: 60, pollInterval: .milliseconds(50))
        scheduler.stop()

        #expect(await log.execs == 2)
    }

    /// 预热轮的判据必须**逐主机**：CPU 使用率要两次采样差分，而基线存在
    /// `MetricCollector.previousCPU[host.id]` 里，本就是每台一份。
    /// 用全局 `metrics.isEmpty` 会让「已有 N 台在线时新增第 N+1 台」不跑预热轮，
    /// 新主机的 CPU 环要挂满一个 interval（默认 30s）才点亮。
    /// 其余预热/防抖用例全是单主机，测不到这个。
    @Test("已有基线时新增一台主机，预热轮照跑")
    func warmUpRunsForNewlyAddedHost() async throws {
        // 可控时钟并把「上次采集」推出 5s 防抖窗口，只考察预热轮这一个变量。
        let clock = MutableClock()
        let (scheduler, log) = makeScheduler(now: { clock.now })
        let existing = host("h1", address: "10.0.0.1")
        let added = host("h2", address: "10.0.0.2")
        await scheduler.scanNow(hosts: [existing])      // exec 1：h1 建立基线
        let before = await log.execs
        clock.advance(by: 10)

        scheduler.startDashboard(hosts: [existing, added], interval: .seconds(600))

        // 立即那一轮：两台各一次。因果等待，几乎瞬间完成。
        await waitUntilExecCount(log, atLeast: before + 2)
        // 预热轮绑的是生产代码里真实的 2s `Task.sleep`（不受 MutableClock 影响），
        // 传非零 pollInterval 让轮询真的睡过这段墙钟时间，事件一落地立刻返回。
        // 若 needsWarmUp 退回 `metrics.isEmpty`：metrics 里已有 h1 → 恒 false →
        // 预热轮永不发生，耗尽上限后 execs 停在 before+2，下面的断言如实失败。
        await waitUntilExecCount(log, atLeast: before + 4, maxAttempts: 80, pollInterval: .milliseconds(50))
        scheduler.stop()

        #expect(await log.execs == before + 4)
    }

    @Test("距上次采集不足 5 秒时不重采")
    func debouncesRapidRestarts() async throws {
        let clock = MutableClock()
        let (scheduler, log) = makeScheduler(now: { clock.now })
        let target = host()
        await scheduler.scanNow(hosts: [target])
        let before = await log.execs

        clock.advance(by: 2)                            // 只过了 2 秒
        scheduler.startDashboard(hosts: [target], interval: .seconds(600))
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        #expect(await log.execs == before)
    }

    /// 新增主机后 5s 内切走再切回：防抖不该把「立即那一轮」也吃掉，
    /// 否则新卡片要挂着骨架一整个 interval（叠加了预热轮跳过就更糟）。
    @Test("有主机缺基线时不防抖")
    func doesNotDebounceWhenAHostLacksBaseline() async throws {
        let clock = MutableClock()
        let (scheduler, log) = makeScheduler(now: { clock.now })
        let existing = host("h1", address: "10.0.0.1")
        let added = host("h2", address: "10.0.0.2")
        await scheduler.scanNow(hosts: [existing])
        let before = await log.execs

        clock.advance(by: 2)                            // 落在 5s 防抖窗口内
        scheduler.startDashboard(hosts: [existing, added], interval: .seconds(600))
        await waitUntilExecCount(log, atLeast: before + 2)
        scheduler.stop()

        #expect(await log.execs >= before + 2)
    }

    @Test("force 绕过防抖")
    func forceBypassesDebounce() async throws {
        let clock = MutableClock()
        let (scheduler, log) = makeScheduler(now: { clock.now })
        let target = host()
        await scheduler.scanNow(hosts: [target])
        let before = await log.execs

        clock.advance(by: 2)
        scheduler.startDashboard(hosts: [target], interval: .seconds(600), force: true)
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        #expect(await log.execs == before + 1)
    }

    // MARK: - 回前台恢复

    @Test("后台不足 30 秒时回前台不动作")
    func shortBackgroundDoesNothing() async throws {
        let (scheduler, log) = makeScheduler()
        let target = host()
        scheduler.startDashboard(hosts: [target], interval: .seconds(600))
        try await Task.sleep(for: .milliseconds(300))
        let before = await log.execs

        await scheduler.resumeAfterBackground(idleFor: 10)
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        #expect(await log.execs == before)
    }

    @Test("后台超过 30 秒时回前台驱逐会话并强制重采")
    func longBackgroundReconnects() async throws {
        let (scheduler, log) = makeScheduler()
        let target = host()
        scheduler.startDashboard(hosts: [target], interval: .seconds(600))
        try await Task.sleep(for: .milliseconds(300))
        let execsBefore = await log.execs
        let connectsBefore = await log.connects

        await scheduler.resumeAfterBackground(idleFor: 60)
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        #expect(await log.execs > execsBefore)
        // 会话被驱逐过，必须重新握手
        #expect(await log.connects == connectsBefore + 1)
    }

    /// `stop()` 之后回前台必须完全 no-op——这条分支此前零覆盖。
    ///
    /// `invalidateAll()` 关的是**整条 SSH 连接**，而 `ConnectionManager` 是全 App
    /// 唯一的连接池：终端交互式 shell、日志 `tail -f`、文件编辑器跨会话持有的
    /// sftp handle 都骑在同一条连接上。`dashboardConfig` 若不随 `stop()` 清空，
    /// 它从 App 启动（服务器是默认 Tab）起就永不为 nil，`resumeAfterBackground`
    /// 的 guard 恒真——用户开着终端切走 30s 再回来，会话就被我们自己关了。
    @Test("stop() 之后回前台完全不动作：不驱逐会话、不采集")
    func resumeAfterStopIsNoOp() async throws {
        let fixture = makeFixture()
        let scheduler = fixture.scheduler
        let target = host()
        // 建立池中会话（代表终端/日志流骑着的那条长命连接）。
        await scheduler.scanNow(hosts: [target])
        // 走一遍真实路径：仪表盘起过，于是 dashboardConfig 被写上。
        scheduler.startDashboard(hosts: [target], interval: .seconds(600))
        // 仪表盘不可见（ServersView.onDisappear）。
        scheduler.stop()
        let execsBefore = await fixture.log.execs
        #expect(await fixture.manager.activeCount == 1)

        await scheduler.resumeAfterBackground(idleFor: 60)
        try await Task.sleep(for: .milliseconds(300))

        #expect(await fixture.log.execs == execsBefore)
        // 关键断言：会话仍在池里，长命通道没被掐断。
        #expect(await fixture.manager.activeCount == 1)
    }

    // MARK: - 并发收敛（代次）

    /// `stop()` 只能 `cancel()` 轮询 Task，而采集全程挂在 await 上，取消追不上它。
    /// 代次是数据侧的判据：作废的旧轮即便跑完，也一个字节都写不进去。
    @Test("stop() 之后旧轮的写回一律作废")
    func staleRoundWritesAreDropped() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        let gate = Gate()
        await log.armGate(gate)

        let scan = Task { await scheduler.scanNow(hosts: [target]) }
        await waitUntilExecCount(log, atLeast: 1)
        #expect(scheduler.phases[target.id] == .collecting)

        scheduler.stop()                       // 代次递增：这一轮从此作废
        #expect(scheduler.phases.isEmpty)

        await gate.open()
        await scan.value                       // 旧轮跑完了

        // 采集本身成功了，但写回全部被丢弃：既不写读数，也不重新点亮 phases，
        // 更不更新 lastScanAt（否则会误触发下一次 startDashboard 的防抖）。
        #expect(scheduler.metrics[target.id] == nil)
        #expect(scheduler.phases.isEmpty)
        #expect(scheduler.lastScanAt == nil)
    }
}
