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
}
