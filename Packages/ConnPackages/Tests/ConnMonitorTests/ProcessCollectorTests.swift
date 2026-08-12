import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

struct ProcessCollectorTests {
    @Test("基础指标命令不再包含进程查询")
    func baseMetricsCommandExcludesProcesses() {
        let command = CollectionScript.command(includeExtended: true)

        #expect(!command.contains("ps -eo"))
        #expect(!command.contains("top -bn1"))
    }

    @Test("进程采集只执行进程命令并解析 GNU ps")
    func collectsProcessesWithoutBaseMetrics() async throws {
        let recorder = ProcessCommandRecorder()
        let session = ProcessFixtureSession(recorder: recorder, output: Self.gnuOutput)

        let result = try await ProcessCollector().collect(
            session: session,
            profile: RemotePlatformProfile(kind: .linux)
        )
        let processes = result.processes

        #expect(processes.count == 2)
        #expect(processes.first?.pid == 1)
        #expect(processes[1].command == "nginx")
        let command = try #require(await recorder.commands.first)
        #expect(command.contains("ps -eo"))
        #expect(command.contains("top -bn1"))
        #expect(!command.contains("/proc/stat"))
        #expect(!command.contains("/proc/meminfo"))
    }

    @Test("collector 按画像选择 Darwin provider")
    func collectsDarwinProcesses() async throws {
        let recorder = ProcessCommandRecorder()
        let session = ProcessFixtureSession(recorder: recorder, output: """
        __CONN_DARWIN_PROCESS_PS__
          PID PPID USER %CPU %MEM RSS STAT ELAPSED COMMAND
          42 1 ops 3.5 1.2 2048 S 00:01:05 /usr/bin/sample --flag
        __CONN_DARWIN_PROCESS_END__
        """)

        let result = try await ProcessCollector().collect(
            session: session, profile: RemotePlatformProfile(kind: .macOS)
        )

        #expect(result.processes.first?.pid == 42)
        guard case .degraded = result.capabilityState else {
            Issue.record("expected degraded Darwin capability")
            return
        }
        let command = try #require(await recorder.commands.first)
        #expect(command.contains("ps -axo"))
    }

    private static let gnuOutput = """
    __CONN_PROCESS_PS__
      PID  PPID USER      %CPU %MEM   RSS NLWP STAT ELAPSED COMMAND
        1     0 root       0.0  0.1  8500    1 Ss   864000 /sbin/init
      234     1 www-data  12.5  4.2 120000    4 S    8130 nginx: worker process
    __CONN_PROCESS_TOP__
    __CONN_PROCESS_END__
    """
}

private actor ProcessCommandRecorder {
    private(set) var commands: [String] = []

    func append(_ command: String) {
        commands.append(command)
    }
}

private final class ProcessFixtureSession: SSHSession {
    let state: AsyncStream<SSHSessionState>
    let isConnected = true

    private let recorder: ProcessCommandRecorder
    private let output: String
    private let continuation: AsyncStream<SSHSessionState>.Continuation

    init(recorder: ProcessCommandRecorder, output: String) {
        self.recorder = recorder
        self.output = output
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        await recorder.append(command)
        return ExecResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
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
