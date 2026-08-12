import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Testing
@testable import Conn

@MainActor
struct LogStreamViewModelTests {
    @Test("停止日志跟随会关闭独占 SSH 会话")
    func stopClosesDedicatedSession() async throws {
        let lifecycle = LogStreamLifecycle()
        let manager = ConnectionManager(
            transport: LogStreamTransport(lifecycle: lifecycle)
        )
        let host = Host(
            id: "logs",
            name: "Logs",
            address: "10.0.0.9",
            username: "ops"
        )
        let viewModel = LogStreamViewModel(
            host: host,
            connectionManager: manager,
            source: LogSource(
                id: "system",
                title: "System",
                subtitle: "/var/log/system.log",
                kind: .file(path: "/var/log/system.log")
            )
        )

        viewModel.start()
        #expect(await lifecycle.waitUntilStarted())

        viewModel.stop()

        #expect(await lifecycle.waitUntilClosed())
        #expect(await manager.activeCount == 0)
    }

    @Test("握手期间停止时晚到的独占会话也会被关闭")
    func stopDuringConnectClosesLateSession() async throws {
        let lifecycle = LogStreamLifecycle()
        let gate = LogConnectGate()
        let manager = ConnectionManager(
            transport: DelayedLogStreamTransport(lifecycle: lifecycle, gate: gate)
        )
        let viewModel = LogStreamViewModel(
            host: Host(
                id: "late-logs",
                name: "Late Logs",
                address: "10.0.0.10",
                username: "ops"
            ),
            connectionManager: manager,
            source: LogSource(
                id: "system",
                title: "System",
                subtitle: "/var/log/system.log",
                kind: .file(path: "/var/log/system.log")
            )
        )

        viewModel.start()
        #expect(await gate.waitUntilConnectStarted())
        viewModel.stop()
        await gate.release()

        #expect(await lifecycle.waitUntilClosed())
        #expect(await !lifecycle.hasStarted)
    }
}

private actor LogStreamLifecycle {
    private var started = false
    private var closed = false
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    var hasStarted: Bool { started }

    func install(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        streamContinuation = continuation
        started = true
    }

    func close() {
        closed = true
        streamContinuation?.finish()
        streamContinuation = nil
    }

    func waitUntilStarted() async -> Bool {
        await waitUntil { started }
    }

    func waitUntilClosed() async -> Bool {
        await waitUntil { closed }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

private actor LogConnectGate {
    private var connectStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        connectStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilConnectStarted() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if connectStarted { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return connectStarted
    }
}

private final class LogStreamTransport: SSHTransport {
    private let lifecycle: LogStreamLifecycle

    init(lifecycle: LogStreamLifecycle) {
        self.lifecycle = lifecycle
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        LogStreamSession(lifecycle: lifecycle)
    }
}

private final class DelayedLogStreamTransport: SSHTransport {
    private let lifecycle: LogStreamLifecycle
    private let gate: LogConnectGate

    init(lifecycle: LogStreamLifecycle, gate: LogConnectGate) {
        self.lifecycle = lifecycle
        self.gate = gate
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        await gate.waitForRelease()
        return LogStreamSession(lifecycle: lifecycle)
    }
}

private final class LogStreamSession: SSHSession {
    let state: AsyncStream<SSHSessionState>
    let isConnected = true

    private let lifecycle: LogStreamLifecycle
    private let stateContinuation: AsyncStream<SSHSessionState>.Continuation

    init(lifecycle: LogStreamLifecycle) {
        self.lifecycle = lifecycle
        (state, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        throw SSHError.channelClosed
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        await lifecycle.install(continuation)
        return stream
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        throw SSHError.channelClosed
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        throw SSHError.channelClosed
    }

    func sftp() async throws -> any RemoteFileSystem {
        throw SSHError.channelClosed
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        throw SSHError.channelClosed
    }

    func close() async {
        await lifecycle.close()
        stateContinuation.yield(.closed)
        stateContinuation.finish()
    }
}
