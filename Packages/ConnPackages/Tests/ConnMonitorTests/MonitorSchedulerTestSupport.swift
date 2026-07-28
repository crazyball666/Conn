import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

/// `MonitorScheduler` 两个测试套件（采集阶段与重试 / 采集时机与并发收敛）共用的
/// 假引擎与等待工具。放在独立文件里，是为了让两个套件都能取到同一套 mock，
/// 同时把单文件行数压在 SwiftLint 的 `file_length` 之下。
typealias DomainHost = ConnKit.Host

/// 记录握手与命令次数，并按预设让前 N 次 exec 抛错（模拟后台期间死掉的会话）。
actor CallLog {
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
/// 用数组而非单个 `CheckedContinuation?` 存等待者：单槽位的版本在第二个等待者到来时
/// 会**静默覆盖**第一个，`open()` 只唤醒最后那个，被覆盖的那个永远醒不过来 → 测试挂死。
/// 「一轮采集钉在闸门上时再发一轮」正是需要两个等待者的场景（`inFlight` 的变异验证），
/// 挂死会把「断言失败」伪装成「测试超时」。
actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

final class FlakyTransport: SSHTransport {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func connect(
        _ endpoint: SSHEndpoint, username: String, auth: SSHAuth, hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        await log.recordConnect()
        return FlakySession(log: log)
    }
}

final class FlakySession: SSHSession {
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

/// 可手动推进的时钟，用于测防抖。
final class MutableClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// 一套装好的被测组合：调度器 + 它用的连接池 + 调用记录。
///
/// 用具名 struct 而非三元组——三元组会撞 SwiftLint 的 `large_tuple`（上限 2 个成员）。
@MainActor
struct SchedulerFixture {
    let scheduler: MonitorScheduler
    let manager: ConnectionManager
    let log: CallLog
}

/// 需要直接断言连接池状态（例如「会话有没有被 `invalidateAll` 掐掉」）时用这个。
@MainActor
func makeFixture(execFailures: Int = 0, now: (() -> Date)? = nil) -> SchedulerFixture {
    let log = CallLog(execFailures: execFailures)
    let manager = ConnectionManager(transport: FlakyTransport(log: log))
    let scheduler = now.map { MonitorScheduler(connectionManager: manager, now: $0) }
        ?? MonitorScheduler(connectionManager: manager)
    return SchedulerFixture(scheduler: scheduler, manager: manager, log: log)
}

/// 大多数用例只关心调度器与调用记录。`now` 传入可控时钟即可测防抖。
@MainActor
func makeScheduler(execFailures: Int = 0, now: (() -> Date)? = nil) -> (MonitorScheduler, CallLog) {
    let fixture = makeFixture(execFailures: execFailures, now: now)
    return (fixture.scheduler, fixture.log)
}

func makeHost(_ id: String = "h1", address: String = "10.0.0.1") -> DomainHost {
    DomainHost(id: id, name: "web", address: address, username: "root")
}

/// 有上限地轮询，直到 `phases[hostID]` 满足 `predicate` 或耗尽 `maxAttempts`。
///
/// 不用定长 `Task.sleep` 一把等到底——等太短会偶发失败，等太长会拖慢测试；
/// 这里是「事件一落地就立刻返回」的因果等待，只是给了个上限兜底。
/// 等不到时**必须报错**而不是静默返回，理由见 `waitUntilExecCount`。
@MainActor
func waitUntilPhase(
    _ scheduler: MonitorScheduler, hostID: String,
    satisfies predicate: (CollectPhase?) -> Bool, maxAttempts: Int = 200,
    pollInterval: Duration = .milliseconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<maxAttempts {
        if predicate(scheduler.phases[hostID]) { return }
        try? await Task.sleep(for: pollInterval)
    }
    let actual = String(describing: scheduler.phases[hostID])
    let message: String = """
        等待 phases[\(hostID)] 满足条件超时（\(maxAttempts) 次 × \(pollInterval)），当前值 \(actual)。
        紧随其后的断言读到的是等待前的旧值，不要当作被测行为的证据。
        """
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
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
///
/// - Parameter pollInterval: 每次重试之间真的睡多久。**必须非零**，默认 5ms。
///   曾经默认 `.zero`（只 `Task.yield()`），已实测 flaky：`yield` 烧的是 CPU 周期而非
///   墙钟时间，而被等的事件跑在 MainActor / 协作线程池上（`connect`/`exec` 是
///   非隔离 async，并行执行测试时还要和别的用例抢线程），200 次 yield 完全可能在
///   事件落地前就耗尽。之后函数**静默返回**，紧跟的 `#expect` 读到等待前的旧值，
///   于是报出来的是一条与真实缺陷无关的断言失败。真睡过一小段墙钟，
///   既让出线程也推进时间，同时仍是「事件一发生就立刻返回」的因果等待。
///
/// 耗尽上限时 `Issue.record` 而非静默返回：静默返回是这类等待工具最危险的性质——
/// 它把「等待超时」伪装成「被测行为不对」，让排查方向从一开始就是错的。
func waitUntilExecCount(
    _ log: CallLog, atLeast target: Int, maxAttempts: Int = 200,
    pollInterval: Duration = .milliseconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<maxAttempts {
        if await log.execs >= target { return }
        try? await Task.sleep(for: pollInterval)
    }
    let actual = await log.execs
    let message: String = """
        等待 execs >= \(target) 超时（\(maxAttempts) 次 × \(pollInterval)），实际 \(actual)。
        紧随其后的断言读到的是等待前的旧值，不要当作被测行为的证据。
        """
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}
