import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

private typealias DomainHost = ConnKit.Host

/// 记录握手与命令次数，并按预设让前 N 次 exec 抛错（模拟后台期间死掉的会话）。
private actor CallLog {
    private(set) var connects = 0
    private(set) var execs = 0
    private var failuresRemaining: Int
    /// 装上后，「成功」的 exec 调用会在返回前挂起，直到测试放行——
    /// 用来把采集钉在飞行中，好读到 phases 的中间态（.collecting/.reconnecting）。
    private var gate: Gate?

    init(execFailures: Int = 0) { failuresRemaining = execFailures }

    func recordConnect() { connects += 1 }

    /// 追加 n 次待失败的 exec（测试中途注入死会话）。
    func failNext(_ count: Int) { failuresRemaining += count }

    /// 返回 true 表示本次 exec 应当抛错。
    func shouldFailExec() -> Bool {
        execs += 1
        guard failuresRemaining > 0 else { return false }
        failuresRemaining -= 1
        return true
    }

    /// 装闸门：此后（在 shouldFailExec 判定为不失败之后）的 exec 调用会挂起等放行。
    func armGate(_ gate: Gate) {
        self.gate = gate
    }

    /// exec 成功路径调用：若装了闸门则在此挂起，直到测试 `open()`。
    func waitIfGated() async {
        if let gate {
            await gate.wait()
        }
    }
}

/// 由测试控制开合的闸门：`exec` 在此挂起，直到测试放行。
///
/// 现有 `FlakySession.exec` 立即返回，抓不到「采集进行中」这个中间态；
/// 用闸门把 exec 的返回钉在测试选定的时刻，才能确定性地读到
/// `phases` 里的 `.collecting`/`.reconnecting`，而不必靠 `Task.sleep` 赌一个大概率够用的时长。
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class FlakyTransport: SSHTransport {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func connect(
        _ endpoint: SSHEndpoint, username: String, auth: SSHAuth, hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        await log.recordConnect()
        return FlakySession(log: log)
    }
}

private final class FlakySession: SSHSession {
    private let log: CallLog
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation

    init(log: CallLog) {
        self.log = log
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        if await log.shouldFailExec() { throw SSHError.channelClosed }
        // 闸门只挡「成功」路径：失败路径要保持即时、确定，不受闸门影响。
        await log.waitIfGated()
        // 空输出即可：MetricParser 解析出全 nil 的 HostMetrics，但字典里是非 nil 值，
        // 足以让「这台主机已知可用」成立。
        return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

@MainActor
@Suite("MonitorScheduler — 采集阶段与重试")
struct MonitorSchedulerTests {
    private func makeScheduler(execFailures: Int = 0) -> (MonitorScheduler, CallLog) {
        let log = CallLog(execFailures: execFailures)
        let manager = ConnectionManager(transport: FlakyTransport(log: log))
        return (MonitorScheduler(connectionManager: manager), log)
    }

    private func host(_ id: String = "h1") -> DomainHost {
        DomainHost(id: id, name: "web", address: "10.0.0.1", username: "root")
    }

    /// 有上限地轮询，直到 `phases[hostID]` 满足 `predicate` 或耗尽 `maxAttempts`。
    ///
    /// 不用 `Task.sleep` 定长等待——等太短会偶发失败，等太长会拖慢测试；
    /// `Task.yield()` 只是把 MainActor 让给排队中的采集 Task，一旦状态更新到位就立即返回。
    private func waitUntilPhase(
        _ scheduler: MonitorScheduler, hostID: String,
        satisfies predicate: (CollectPhase?) -> Bool, maxAttempts: Int = 200
    ) async {
        for _ in 0..<maxAttempts {
            if predicate(scheduler.phases[hostID]) { return }
            await Task.yield()
        }
    }

    /// 有上限地轮询，直到 `log.execs` 达到 `target` 或耗尽 `maxAttempts`。
    ///
    /// 用于精确定位到「第 N 次 exec 调用已经开始」这个时间点——比直接轮询
    /// `phases` 更稳：`phases` 在一轮里可能被多次 attempt 先后写入（例如失败重试前的
    /// 那次 attempt 也会短暂写一个值），直接等某个 phase 值出现，可能撞上前一次
    /// attempt 的瞬时值而非我们真正要观察的那次，从而在某些错误实现下误判通过。
    /// 而 `execs` 计数单调递增，等到第 N 次 exec 已开始，就能保证 `phases`
    /// 已经是「这次 attempt」在函数顶部写下的、稳定不会再变的值
    /// （因为这次 exec 挂在闸门上，不会往下走到下一次 attempt）。
    private func waitUntilExecCount(_ log: CallLog, atLeast target: Int, maxAttempts: Int = 200) async {
        for _ in 0..<maxAttempts {
            if await log.execs >= target { return }
            await Task.yield()
        }
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
