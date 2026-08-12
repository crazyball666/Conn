import Foundation
import Testing
@testable import ConnSSH

@Suite("RemoteProcessChannel contracts")
struct RemoteProcessChannelTests {
    @Test("request 精确表达 direct exec 与可选 PTY")
    func requestCarriesOptionalTerminal() {
        let terminal = RemoteTerminalRequest(
            type: "xterm-256color",
            size: .init(cols: 120, rows: 40),
            modes: [.echo: 0, .canonicalInput: 1]
        )
        let withPTY = RemoteProcessRequest(command: "tmux -CC attach", terminal: terminal)
        let withoutPTY = RemoteProcessRequest(command: "cat", terminal: nil)

        #expect(withPTY.command == "tmux -CC attach")
        #expect(withPTY.terminal == terminal)
        #expect(withPTY.terminal?.modes[.echo] == 0)
        #expect(withoutPTY.terminal == nil)
    }

    @Test("terminal mode 使用 SSH opcode，保留未来扩展空间")
    func terminalModeUsesSSHOpcode() {
        #expect(RemoteTerminalMode.echo.rawValue == 53)
        #expect(RemoteTerminalMode.canonicalInput.rawValue == 51)
        #expect(RemoteTerminalMode(rawValue: 200).rawValue == 200)
    }

    @Test("stdout、stderr 与退出状态保持结构化且可比较")
    func outputAndExitAreStructuredValues() {
        let stdout = RemoteProcessOutput.stdout(Data("out".utf8))
        let stderr = RemoteProcessOutput.stderr(Data("err".utf8))
        let exit = RemoteProcessExit(exitCode: 143, signal: "TERM")

        #expect(stdout != stderr)
        #expect(exit == RemoteProcessExit(exitCode: 143, signal: "TERM"))
        #expect(RemoteProcessExit(exitCode: nil, signal: nil).exitCode == nil)
    }

    @Test("旧 transport 默认明确报告 unsupported，不回退到 shell")
    func unsupportedDefaultDoesNotFallback() async {
        let session = UnsupportedProcessSession()

        await #expect(throws: RemoteProcessError.unsupported) {
            try await session.openProcess(RemoteProcessRequest(command: "tmux", terminal: nil))
        }
        #expect(session.openShellCallCount == 0)
    }

    @Test("bounded bridge 在容量内严格保序")
    func boundedBridgePreservesOrder() async throws {
        let bridge = RemoteProcessOutputBridge(maxBufferedChunks: 3)
        let expected: [RemoteProcessOutput] = [
            .stdout(Data("one".utf8)),
            .stderr(Data("two".utf8)),
            .stdout(Data("three".utf8)),
        ]

        for output in expected {
            #expect(bridge.yield(output))
        }
        bridge.finish()

        var received: [RemoteProcessOutput] = []
        for try await output in bridge.stream {
            received.append(output)
        }
        #expect(received == expected)
    }

    @Test("bounded bridge 首次溢出后报错且不再接受输出")
    func boundedBridgeFailsOnOverflow() async {
        let counter = TerminationCounter()
        let bridge = RemoteProcessOutputBridge(maxBufferedChunks: 2) {
            counter.increment()
        }
        let first = RemoteProcessOutput.stdout(Data("one".utf8))
        let second = RemoteProcessOutput.stderr(Data("two".utf8))

        #expect(bridge.yield(first))
        #expect(bridge.yield(second))
        #expect(!bridge.yield(.stdout(Data("overflow".utf8))))
        #expect(!bridge.yield(.stdout(Data("late".utf8))))

        var received: [RemoteProcessOutput] = []
        do {
            for try await output in bridge.stream {
                received.append(output)
            }
            Issue.record("overflow stream 应抛出结构化错误")
        } catch {
            #expect(error as? RemoteProcessError == .outputBufferOverflow(maxBufferedChunks: 2))
        }
        #expect(received == [first, second])
        #expect(counter.value == 1)
    }

    @Test("bounded bridge 的任意结束路径只回调一次")
    func boundedBridgeTerminatesExactlyOnce() async {
        let normalCounter = TerminationCounter()
        let normal = RemoteProcessOutputBridge(maxBufferedChunks: 1) {
            normalCounter.increment()
        }
        normal.finish()
        normal.finish()
        normal.finish(throwing: SSHError.channelClosed)
        #expect(normalCounter.value == 1)

        let failedCounter = TerminationCounter()
        let failed = RemoteProcessOutputBridge(maxBufferedChunks: 1) {
            failedCounter.increment()
        }
        failed.finish(throwing: SSHError.channelClosed)
        failed.finish()
        #expect(failedCounter.value == 1)

        let cancelledCounter = TerminationCounter()
        let cancelled = RemoteProcessOutputBridge(maxBufferedChunks: 1) {
            cancelledCounter.increment()
        }
        let consumer = Task {
            do {
                for try await _ in cancelled.stream {}
            } catch {}
        }
        await Task.yield()
        consumer.cancel()
        await consumer.value
        #expect(await waitUntil { cancelledCounter.value == 1 })
        cancelled.finish()
        #expect(cancelledCounter.value == 1)
    }
}

private final class TerminationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private final class UnsupportedProcessSession: SSHSession, @unchecked Sendable {
    let state = AsyncStream<SSHSessionState> { continuation in continuation.finish() }
    let isConnected = true
    private(set) var openShellCallCount = 0

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        throw SSHError.channelClosed
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw SSHError.channelClosed
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        throw SSHError.channelClosed
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        openShellCallCount += 1
        throw SSHError.channelClosed
    }

    func sftp() async throws -> any RemoteFileSystem {
        throw SSHError.channelClosed
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        throw SSHError.channelClosed
    }

    func close() async {}
}
