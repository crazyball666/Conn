import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

@MainActor
struct ProcessMonitorTests {
    @Test("基础指标采集阻塞时进程采集仍独立完成并复用连接")
    func processCollectionDoesNotWaitForMetrics() async {
        let log = SplitCollectionLog()
        let manager = ConnectionManager(
            transport: SplitCollectionTransport(log: log),
            platformDetector: FixturePlatformDetector(profile: RemotePlatformProfile(kind: .linux))
        )
        let metricsMonitor = MonitorScheduler(connectionManager: manager, collectDeadline: .seconds(600))
        let processMonitor = ProcessMonitor(connectionManager: manager)
        let host = Host(id: "split", name: "split", address: "10.0.0.8", username: "root")
        let metricsDone = CompletionFlag()

        let metricsTask = Task {
            await metricsMonitor.scanNow(hosts: [host])
            metricsDone.isDone = true
        }
        await waitUntil { await log.baseCommands == 1 }

        processMonitor.start(host: host, interval: .seconds(600))
        await waitUntil { processMonitor.processes.count == 1 }

        #expect(processMonitor.processes.first?.command == "nginx")
        #expect(!metricsDone.isDone)
        #expect(await log.processCommands == 1)
        #expect(await log.connects == 1)

        processMonitor.stop()
        metricsMonitor.stop()
        await log.releaseBaseCollection()
        await metricsTask.value
    }

    @Test("旧采集未结束时返回进程页会在旧轮结束后立即补采")
    func returningWhilePreviousCollectionIsInFlightQueuesRefresh() async {
        let log = SplitCollectionLog()
        let manager = ConnectionManager(
            transport: SplitCollectionTransport(log: log),
            platformDetector: FixturePlatformDetector(profile: RemotePlatformProfile(kind: .linux))
        )
        let processMonitor = ProcessMonitor(connectionManager: manager)
        let host = Host(id: "return", name: "return", address: "10.0.0.9", username: "root")

        await log.holdNextProcessCollection()
        processMonitor.start(host: host, interval: .seconds(600))
        await waitUntil { await log.processCommands == 1 }

        processMonitor.stop()
        processMonitor.start(host: host, interval: .seconds(600))
        await log.releaseProcessCollection()
        await waitUntil { await log.processCommands == 2 }

        #expect(await log.processCommands == 2)
        #expect(processMonitor.processes.first?.command == "nginx")
        processMonitor.stop()
    }

    private func waitUntil(
        maxAttempts: Int = 200,
        condition: () async -> Bool
    ) async {
        for _ in 0 ..< maxAttempts {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("等待独立采集状态超时")
    }
}

private actor SplitCollectionLog {
    private(set) var connects = 0
    private(set) var baseCommands = 0
    private(set) var processCommands = 0
    private var baseWaiters: [CheckedContinuation<Void, Never>] = []
    private var processWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldHoldNextProcess = false

    func recordConnect() { connects += 1 }

    func execute(_ command: String) async -> ExecResult {
        if command.contains("/proc/stat") {
            baseCommands += 1
            await withCheckedContinuation { baseWaiters.append($0) }
            return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        if command.contains("ps -eo") {
            processCommands += 1
            if shouldHoldNextProcess {
                shouldHoldNextProcess = false
                await withCheckedContinuation { processWaiters.append($0) }
            }
            return ExecResult(exitCode: 0, stdout: Data(Self.processOutput.utf8), stderr: Data())
        }
        return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func releaseBaseCollection() {
        let waiters = baseWaiters
        baseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func holdNextProcessCollection() {
        shouldHoldNextProcess = true
    }

    func releaseProcessCollection() {
        let waiters = processWaiters
        processWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private static let processOutput = """
    __CONN_PROCESS_PS__
      PID  PPID USER      %CPU %MEM   RSS NLWP STAT ELAPSED COMMAND
      234     1 www-data  12.5  4.2 120000    4 S    8130 nginx: worker process
    __CONN_PROCESS_TOP__
    __CONN_PROCESS_END__
    """
}

private final class SplitCollectionTransport: SSHTransport {
    private let log: SplitCollectionLog

    init(log: SplitCollectionLog) {
        self.log = log
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        await log.recordConnect()
        return SplitCollectionSession(log: log)
    }
}

private final class SplitCollectionSession: SSHSession {
    let state: AsyncStream<SSHSessionState>
    let isConnected = true

    private let log: SplitCollectionLog
    private let continuation: AsyncStream<SSHSessionState>.Continuation

    init(log: SplitCollectionLog) {
        self.log = log
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        await log.execute(command)
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}
