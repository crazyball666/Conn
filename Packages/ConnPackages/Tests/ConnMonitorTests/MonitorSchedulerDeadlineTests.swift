import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

/// 单台主机采集的**放弃式截止时间**（`collectDeadline`）。
///
/// 被测缺陷：`scanOnce` 用 `withTaskGroup` 收敛一轮，而任务组必须等所有子任务
/// 真正结束才返回；采集链路最终挂在不响应 Swift 并发取消的 NIO future 上
/// （Citadel 的 exec 请求那一步没有任何兜底，半开 TCP 下会挂到 TCP RTO，分钟级）。
/// 一台主机卡住 → 那一轮 `scanOnce` 不返回 → `startDashboard` 的循环走不到 `sleep`
/// → **后续轮次永远不开始**，其余主机的读数就此停更。
///
/// 这四条用例覆盖修复的四个承重点：整轮按时返回、卡住的主机留在 `inFlight`、
/// 孤儿自行清理、正常路径零额外延迟。
///
/// **本文件所有等待都有上限**：被测缺陷的形态就是「永远不返回」，用无上限的
/// `await task.value` 去等，一旦实现退回结构化等待，看到的会是「测试永久卡住」
/// 而不是「断言失败」——排查方向从一开始就是错的。
@MainActor
@Suite("MonitorScheduler — 采集轮次截止时间")
struct MonitorSchedulerDeadlineTests {
    private let stuck = makeHost("h1", address: "10.0.0.1")
    private let healthy = makeHost("h2", address: "10.0.0.2")

    /// 把一轮 `scanNow` 放进非结构化 Task，返回可轮询的完成标志。
    ///
    /// 调用方**绝不 await 这个 Task**——它可能永远不返回，那正是被测的失效模式。
    private func startScan(
        _ scheduler: MonitorScheduler, hosts: [DomainHost]
    ) -> CompletionFlag {
        let flag = CompletionFlag()
        Task { @MainActor in
            await scheduler.scanNow(hosts: hosts)
            flag.isDone = true
        }
        return flag
    }

    // MARK: - 1. 一台卡住不再拖垮整轮

    @Test("一台主机卡死时整轮仍按 deadline 返回，健康主机的读数照常写回")
    func stuckHostDoesNotStallTheRound() async {
        // deadline 取 200ms：足够短，测试不必真等 45 秒；也足够长，健康主机
        // （假引擎，毫秒级）在窗口内早已采完，不会把「健康主机没写回」误报成缺陷。
        let (scheduler, log) = makeScheduler(collectDeadline: .milliseconds(200))
        let gate = Gate()
        // 只钉住 h1：钉住所有主机的话，测出来的是「整轮都卡住」而不是「整轮没被拖垮」。
        await log.armGate(gate, forAddress: stuck.address)

        let scan = startScan(scheduler, hosts: [stuck, healthy])

        // 上限 3 秒，是 deadline 的 15 倍：正确实现约 200ms 就返回。
        // 退回结构化等待的变异版会耗尽这 3 秒（闸门此刻仍关着），在下一行如实变红。
        let returned = await waitUntilDone(scan, maxAttempts: 300, pollInterval: .milliseconds(10))
        #expect(returned, "scanOnce 必须在 deadline 到点时返回；等不到说明控制权仍被卡住的那台扣着")

        // 整轮没被拖垮的正面证据：健康主机本轮的读数已经落地。
        #expect(scheduler.metrics[healthy.id] != nil)
        #expect(scheduler.phases[healthy.id] == .idle)
        // 卡住那台：我们并不知道它此刻是什么状态，卡片继续转圈才诚实——
        // 超时返回时**不许**把它收成 .idle（收圈是孤儿跑完时的事）。
        #expect(scheduler.phases[stuck.id] == .collecting)
        #expect(scheduler.metrics[stuck.id] == nil)
        #expect(scheduler.errors[stuck.id] == nil)

        // 收尾：放行孤儿并等它真的跑完，不把它留到测试进程结束。
        await gate.open()
        _ = await waitUntilDone(scan, maxAttempts: 300, pollInterval: .milliseconds(10))
        await waitUntilPhase(scheduler, hostID: stuck.id) { $0 == .idle }
    }

    // MARK: - 2. 卡住的主机留在 inFlight，后续轮次跳过它

    @Test("卡死的主机留在 inFlight：后续轮次直接跳过，不叠加第二个孤儿")
    func stuckHostIsSkippedByLaterRounds() async {
        let (scheduler, log) = makeScheduler(collectDeadline: .milliseconds(200))
        let gate = Gate()
        await log.armGate(gate, forAddress: stuck.address)

        let first = startScan(scheduler, hosts: [stuck, healthy])
        #expect(await waitUntilDone(first, maxAttempts: 300, pollInterval: .milliseconds(10)))
        #expect(await log.execs(forAddress: stuck.address) == 1)
        #expect(await log.execs(forAddress: healthy.address) == 1)

        // 第二轮：卡住那台的孤儿还在飞行中（闸门没开），它必须被整轮跳过。
        // 若超时返回时就把 id 移出 `inFlight`，这一轮会对它再起一次采集——
        // 孤儿随轮次累积，每个都占着一条 SSH 通道。
        let second = startScan(scheduler, hosts: [stuck, healthy])
        #expect(await waitUntilDone(second, maxAttempts: 300, pollInterval: .milliseconds(10)))

        #expect(await log.execs(forAddress: stuck.address) == 1)
        // 同时确认第二轮真的跑了（否则上一条断言会因为「第二轮压根没发生」而恒真）。
        #expect(await log.execs(forAddress: healthy.address) == 2)

        await gate.open()
        await waitUntilPhase(scheduler, hostID: stuck.id) { $0 == .idle }
    }

    // MARK: - 3. 孤儿跑完后自己清理 inFlight

    @Test("孤儿跑完后自行退出 inFlight，下一轮重新采集这台主机")
    func orphanReleasesInFlightOnCompletion() async {
        let (scheduler, log) = makeScheduler(collectDeadline: .milliseconds(200))
        let gate = Gate()
        await log.armGate(gate, forAddress: stuck.address)

        let first = startScan(scheduler, hosts: [stuck, healthy])
        #expect(await waitUntilDone(first, maxAttempts: 300, pollInterval: .milliseconds(10)))
        #expect(await log.execs(forAddress: stuck.address) == 1)

        // 放行孤儿。它跑完时会写回读数并收圈——这就是「孤儿已结束」的因果信号，
        // 而 `inFlight` 的移除（defer）在收圈之后、同一次 MainActor 执行片段内完成。
        await gate.open()
        await waitUntilPhase(scheduler, hostID: stuck.id) { $0 == .idle }
        #expect(scheduler.metrics[stuck.id] != nil)

        // 再发一轮：`inFlight` 已被孤儿自己清掉，这台主机必须被重新采集。
        // 若清理挂在 `guard isCurrent` 之后（或干脆没清），这一轮会继续对它让位，
        // exec 计数停在 1，下面的断言如实失败。
        await scheduler.scanNow(hosts: [stuck, healthy])
        #expect(await log.execs(forAddress: stuck.address) == 2)
        #expect(scheduler.phases[stuck.id] == .idle)
    }

    /// 孤儿清理 `inFlight` 必须**无条件**，不能挡在 `guard isCurrent(generation)` 之后。
    ///
    /// 「卡住 → 切走页面（`stop()` 推进代次）→ 切回来」是最容易踩到的真实序列：
    /// 孤儿醒来时代次已变，若清理被代次判据挡住，这台主机就永久留在 `inFlight` 里，
    /// 此后每一轮都对它让位——采集永久停摆，比原来的卡死还难查（没有任何转圈可看）。
    @Test("代次变化后孤儿依然会清掉 inFlight，这台主机不会永久停摆")
    func orphanReleasesInFlightEvenAfterGenerationChange() async {
        let (scheduler, log) = makeScheduler(collectDeadline: .milliseconds(200))
        let gate = Gate()
        await log.armGate(gate, forAddress: stuck.address)

        let first = startScan(scheduler, hosts: [stuck])
        #expect(await waitUntilDone(first, maxAttempts: 300, pollInterval: .milliseconds(10)))
        #expect(await log.execs(forAddress: stuck.address) == 1)

        // 页面切走：代次递增，孤儿从此一个字节也写不进去（phases 也被清空）。
        scheduler.stop()
        await gate.open()

        // 孤儿这次什么状态都不写，没有可观察的因果信号，于是用「下一轮能否重新采到它」
        // 本身作为判据，并给一段有上限的重试窗口（孤儿收尾只需毫秒级）。
        // 清理若被代次判据挡住，这里每一次 scanNow 都会让位，计数永远停在 1。
        var reCollected = false
        for _ in 0..<50 {
            await scheduler.scanNow(hosts: [stuck])
            if await log.execs(forAddress: stuck.address) >= 2 { reCollected = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(reCollected, "代次变化后孤儿没有清掉 inFlight，这台主机再也采不到了")
    }

    // MARK: - 4. 正常路径不受影响

    @Test("无主机卡死时正常路径零额外延迟：立即返回、读数与阶段照旧")
    func normalPathIsNotDelayedByTheDeadline() async {
        // deadline 给到 600 秒，远超本用例 2 秒的等待上限：实现若把「等满 deadline」
        // 错当成「等采集完成」（竞速写反、或忘了在采集完成时兑现续体），
        // 这条会等不到而如实变红，而不是悄悄慢下来还全绿。
        let (scheduler, log) = makeScheduler(collectDeadline: .seconds(600))

        let scan = startScan(scheduler, hosts: [stuck, healthy])
        #expect(await waitUntilDone(scan, maxAttempts: 200, pollInterval: .milliseconds(10)))

        #expect(scheduler.metrics[stuck.id] != nil)
        #expect(scheduler.metrics[healthy.id] != nil)
        #expect(scheduler.phases[stuck.id] == .idle)
        #expect(scheduler.phases[healthy.id] == .idle)
        #expect(scheduler.errors.isEmpty)
        #expect(scheduler.lastScanAt != nil)
        // 每台恰好一次 exec：deadline 既没有让谁重采，也没有让谁被跳过。
        #expect(await log.execs == 2)
    }

    // MARK: - deadline 取值本身

    /// 这个数字是**正确性约束**，不是性能旋钮，所以钉一条测试盯着它。
    ///
    /// 常见的死会话靠「第一次 attempt 撞上 Citadel 的 15 秒兜底 → 抛错 → 驱逐会话 →
    /// 重新握手重试 → 成功」自愈，而一轮 `collectOne` 有两次 attempt，合法耗时可能
    /// 超过 30 秒。deadline 一旦被「优化」到 30 秒以下，就会在自愈完成前把那一轮丢成
    /// 孤儿，制造出「本来能恢复却一直转圈」——比它要修的卡死更糟：卡死只赖住一台，
    /// 这个会让每台可自愈的主机都恢复不了。
    @Test("默认 deadline 显著大于一次完整自愈（两次 attempt）的合法耗时")
    func defaultDeadlineLeavesRoomForSelfHealing() {
        let (scheduler, _) = makeScheduler()   // 不传 → 用生产默认值
        #expect(scheduler.collectDeadline >= .seconds(45))
    }
}
