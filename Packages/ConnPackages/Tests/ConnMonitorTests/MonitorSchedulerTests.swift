import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

@MainActor
@Suite("MonitorScheduler — 采集阶段与重试")
struct MonitorSchedulerTests {
    private func host(_ id: String = "h1", address: String = "10.0.0.1") -> DomainHost {
        makeHost(id, address: address)
    }

    @Test("首采成功后有读数，阶段回到 idle")
    func firstScanPopulatesMetrics() async {
        let (scheduler, log) = makeScheduler()
        let target = host()

        await scheduler.scanNow(hosts: [target])

        #expect(scheduler.metrics[target.id] != nil)
        #expect(scheduler.errors[target.id] == nil)
        #expect(scheduler.phases[target.id] == .idle)
        #expect(await log.execs == 1)
    }

    @Test("调度器按连接的平台画像选择采集能力")
    func routesByDetectedPlatform() async {
        let fixture = makeFixture(platform: .macOS)
        let target = host()

        await fixture.scheduler.scanNow(hosts: [target])

        #expect(fixture.scheduler.metrics[target.id]?.platformProfile.kind == .macOS)
        #expect(await fixture.log.execs == 1)
    }

    @Test("有读数的主机首次 exec 失败会同轮立刻重试，不报错")
    func retriesOnceWithoutSurfacingError() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        // 先采一轮建立「已知可用」
        await scheduler.scanNow(hosts: [target])
        #expect(scheduler.metrics[target.id] != nil)

        // 让下一次 exec 失败一次（模拟死会话）
        await log.failNext(1)
        await scheduler.scanNow(hosts: [target])

        #expect(scheduler.errors[target.id] == nil)
        #expect(scheduler.metrics[target.id] != nil)
        // 第 1 轮 1 次 + 第 2 轮（失败 1 次 + 重试 1 次）= 3
        #expect(await log.execs == 3)
        // 重试前驱逐了会话，所以重新握手了一次
        #expect(await log.connects == 2)
    }

    @Test("重试也失败才认定故障，清空读数")
    func secondFailureSurfacesError() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        await scheduler.scanNow(hosts: [target])

        await log.failNext(2)
        await scheduler.scanNow(hosts: [target])

        #expect(scheduler.errors[target.id] != nil)
        #expect(scheduler.metrics[target.id] == nil)
        #expect(scheduler.phases[target.id] == .idle)
    }

    /// `attempt` 成功路径里的 `errors[host.id] = nil` 双重承重：
    /// 决定详情页错误横幅撤不撤（`HostOverviewViewModel.errorText`），
    /// 也决定 `startDashboard` 的 `needsWarmUp` 判据（只看 `metrics` 不够，
    /// 见该函数注释）。删掉那一行不会让任何既有测试变红——旧测试要么只看
    /// `metrics`，要么在故障判定当下就结束——这里补上「故障主机恢复」这一步，
    /// 把它钉死。
    @Test("故障主机恢复采集成功后，errors 清空且读数写回")
    func recoveryAfterFailureClearsErrors() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        await scheduler.scanNow(hosts: [target])   // 建立基线（已知可用）

        await log.failNext(2)
        await scheduler.scanNow(hosts: [target])   // 首次失败 + 重试仍失败 → 判定故障
        #expect(scheduler.errors[target.id] != nil)
        #expect(scheduler.metrics[target.id] == nil)

        await scheduler.scanNow(hosts: [target])   // 主机恢复，本轮采集成功

        #expect(scheduler.errors[target.id] == nil)
        #expect(scheduler.metrics[target.id] != nil)
    }

    @Test("已判定故障的主机每轮只尝试一次，不再双倍连接")
    func failedHostDoesNotDoubleAttempt() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        await scheduler.scanNow(hosts: [target])   // exec 1
        await log.failNext(2)
        await scheduler.scanNow(hosts: [target])   // exec 2、3 → 判定故障

        await log.failNext(1)
        await scheduler.scanNow(hosts: [target])   // 只该有 exec 4

        #expect(await log.execs == 4)
    }

    @Test("首采失败直接报错，不重试")
    func firstScanFailureSurfacesImmediately() async {
        let (scheduler, log) = makeScheduler(execFailures: 1)
        let target = host()

        await scheduler.scanNow(hosts: [target])

        #expect(scheduler.errors[target.id] != nil)
        #expect(scheduler.metrics[target.id] == nil)
        #expect(await log.execs == 1)
    }

    @Test("stop 清空全部阶段")
    func stopClearsPhases() async {
        let (scheduler, _) = makeScheduler()
        let target = host()
        await scheduler.scanNow(hosts: [target])

        scheduler.stop()

        #expect(scheduler.phases.isEmpty)
    }

    // MARK: - phases 中间态（.collecting / .reconnecting）

    // 以下两条测试直接断言 attempt() 里的关键三元判定：
    //     (needsHandshake && metrics[host.id] != nil) ? .reconnecting : .collecting
    // 之前的测试全部在 scanNow 返回之后断言，而 collectOne 末尾无条件把 phases 收回
    // .idle，所以 .collecting/.reconnecting 这两个值从未被真正校验过——条件写反或
    // 两个 case 互换，旧测试也会照常全绿。这里用 Gate 把 exec 挂在采集进行中，
    // 在 scanNow 尚未返回时读取 phases，堵住这个漏洞。

    @Test("首采（metrics 里没有该主机读数）即便池空，阶段也必须是 collecting 而非 reconnecting")
    func firstScanIsCollectingEvenWithEmptyPool() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        let gate = Gate()
        // 首采本来就没有池化会话，也没有既有读数——这是骨架加载态，不该被判成「重连中」。
        await log.armGate(gate)

        let task = Task { await scheduler.scanNow(hosts: [target]) }
        await waitUntilPhase(scheduler, hostID: target.id) { $0 != nil }
        #expect(scheduler.phases[target.id] == .collecting)

        await gate.open()
        await task.value

        #expect(scheduler.metrics[target.id] != nil)
        #expect(scheduler.phases[target.id] == .idle)
    }

    @Test("已有读数 + 池空（会话被驱逐）时，阶段必须是 reconnecting")
    func retryAfterEvictionIsReconnecting() async {
        let (scheduler, log) = makeScheduler()
        let target = host()

        // 第一轮正常放行，建立「已知可用」的读数。
        await scheduler.scanNow(hosts: [target])
        #expect(scheduler.metrics[target.id] != nil)

        // 第二轮：首次 exec 抛错触发驱逐（池清空），但读数还在——
        // 重试那次 attempt() 应判成 reconnecting。闸门挡在重试的 exec 上，
        // 好在它返回前读到 phases。
        await log.failNext(1)
        let gate = Gate()
        await log.armGate(gate)
        let task = Task { await scheduler.scanNow(hosts: [target]) }

        // 第一次 exec（第 1 轮的 1 次）已经发生；本轮判定故障前会有失败的
        // attempt（第 2 次 exec）+ 重试的 attempt（第 3 次 exec，挂在闸门上）。
        // 等到第 3 次 exec 已开始，才能保证 phases 是「重试那次 attempt」写下的、
        // 稳定不再变的值——直接轮询 phases 的值可能撞上失败那次 attempt 的瞬时值。
        await waitUntilExecCount(log, atLeast: 3)
        #expect(scheduler.phases[target.id] == .reconnecting)

        await gate.open()
        await task.value

        #expect(scheduler.errors[target.id] == nil)
        #expect(scheduler.metrics[target.id] != nil)
        #expect(scheduler.phases[target.id] == .idle)
        // 首轮握手 1 次 + 驱逐后重连 1 次
        #expect(await log.connects == 2)
        // 首轮 1 次 + 第二轮（失败 1 次 + 重试 1 次）
        #expect(await log.execs == 3)
    }
}
