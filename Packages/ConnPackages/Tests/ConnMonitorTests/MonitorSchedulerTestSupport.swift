import ConnKit
import ConnSSH
import Foundation
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
actor Gate {
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
/// 不用 `Task.sleep` 定长等待——等太短会偶发失败，等太长会拖慢测试；
/// `Task.yield()` 只是把 MainActor 让给排队中的采集 Task，一旦状态更新到位就立即返回。
@MainActor
func waitUntilPhase(
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
///
/// - Parameter pollInterval: 每次重试之间真的睡多久。默认 `.zero`，
///   即只 `Task.yield()`——适合观察「同一轮事件循环内」就会落地的状态变化，
///   几乎不消耗真实时间。但如果要等的事件本身在生产代码里绑了真实的
///   `Task.sleep`（例如预热轮的 2s 延迟），空转的 `Task.yield()` 循环会在
///   耗尽 `maxAttempts` 前就早早放弃——它消耗的是 CPU 周期而非墙钟时间，
///   200 次 yield 通常远不够撑满 2 秒。这种情况下传入非零 `pollInterval`，
///   让轮询真的睡过这段墙钟时间，同时仍然是「事件一发生就立刻返回」的因果等待。
func waitUntilExecCount(
    _ log: CallLog, atLeast target: Int, maxAttempts: Int = 200, pollInterval: Duration = .zero
) async {
    for _ in 0..<maxAttempts {
        if await log.execs >= target { return }
        if pollInterval > .zero {
            try? await Task.sleep(for: pollInterval)
        } else {
            await Task.yield()
        }
    }
}
