import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

@Suite("MetricCollector platform routing")
struct MetricCollectorPlatformTests {
    @Test("macOS 首次采样直接使用 top 利用率并保留平台画像")
    func collectsDarwinMetrics() async throws {
        let recorder = MetricCommandRecorder()
        let session = MetricFixtureSession(recorder: recorder, output: Self.darwinOutput)
        let profile = RemotePlatformProfile(
            kind: .macOS, release: "24.1.0", architecture: "arm64", shell: .zsh
        )

        let metrics = try await MetricCollector().collect(
            host: Self.host, session: session, profile: profile
        )

        #expect(metrics.cpu == 20.5)
        #expect(metrics.platformProfile == profile)
        #expect(metrics.capabilityState == .supported)
        let command = try #require(await recorder.commands.first)
        #expect(command.contains("top -l 1"))
        #expect(!command.contains("/proc/"))
    }

    @Test("未支持的平台在执行采集命令前返回结构化错误")
    func rejectsUnsupportedPlatform() async {
        let recorder = MetricCommandRecorder()
        let session = MetricFixtureSession(recorder: recorder, output: "")

        do {
            _ = try await MetricCollector().collect(
                host: Self.host,
                session: session,
                profile: RemotePlatformProfile(kind: .windows)
            )
            Issue.record("expected unsupported platform error")
        } catch let error as MetricCollectionError {
            #expect(error == .unsupportedPlatform(.windows))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await recorder.commands.isEmpty)
    }

    @Test("macOS 默认出口切换时重建网络速率基线")
    func resetsNetworkRateWhenPrimaryInterfaceChanges() async throws {
        let secondOutput = Self.darwinOutput
            .replacingOccurrences(
                of: "__CONN_DARWIN_PRIMARY_INTERFACE__\nen0",
                with: "__CONN_DARWIN_PRIMARY_INTERFACE__\nutun0"
            )
            .replacingOccurrences(of: "123456", with: "123459")
        let session = MetricSequenceSession(outputs: [Self.darwinOutput, secondOutput])
        let collector = MetricCollector()

        _ = try await collector.collect(
            host: Self.host, session: session, profile: .init(kind: .macOS)
        )
        let second = try await collector.collect(
            host: Self.host, session: session, profile: .init(kind: .macOS)
        )

        #expect(second.netRx == 100_000_000)
        #expect(second.netRxRate == nil)
        #expect(second.netTxRate == nil)
    }

    private static let host = ConnKit.Host(
        id: "darwin", name: "Mac", address: "mac.example.com", username: "ops"
    )

    private static let darwinOutput = """
    __CONN_DARWIN_TOP__
    CPU usage: 12.5% user, 8.0% sys, 79.5% idle
    __CONN_DARWIN_CORES__
    8
    __CONN_DARWIN_MEMSIZE__
    17179869184
    __CONN_DARWIN_VMSTAT__
    Mach Virtual Memory Statistics: (page size of 4096 bytes)
    Pages free: 100000.
    Pages inactive: 300000.
    Pages speculative: 10000.
    Pages purgeable: 20000.
    __CONN_DARWIN_DISK__
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk3s1s1 100000000 40000000 60000000 40% /
    __CONN_DARWIN_NET__
    Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
    en0 1500 <Link#4> aa:bb:cc:dd:ee:ff 1000 0 5000000 900 0 3000000 0
    utun0 1380 <Link#20> aa:bb:cc:dd:ee:00 1000 0 100000000 900 0 80000000 0
    __CONN_DARWIN_PRIMARY_INTERFACE__
    en0
    __CONN_DARWIN_UPTIME__
    123456
    __CONN_DARWIN_END__
    """
}

private actor MetricSequenceSession: SSHSession {
    nonisolated let state: AsyncStream<SSHSessionState>
    nonisolated let isConnected = true
    private var outputs: [String]

    init(outputs: [String]) {
        self.outputs = outputs
        state = AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        ExecResult(exitCode: 0, stdout: Data(outputs.removeFirst().utf8), stderr: Data())
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
    func close() async {}
}

private actor MetricCommandRecorder {
    private(set) var commands: [String] = []

    func append(_ command: String) {
        commands.append(command)
    }
}

private final class MetricFixtureSession: SSHSession {
    let state: AsyncStream<SSHSessionState>
    let isConnected = true

    private let recorder: MetricCommandRecorder
    private let output: String
    private let continuation: AsyncStream<SSHSessionState>.Continuation

    init(recorder: MetricCommandRecorder, output: String) {
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
