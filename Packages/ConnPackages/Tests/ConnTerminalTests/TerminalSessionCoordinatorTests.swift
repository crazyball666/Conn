import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnTerminal

private typealias Host = ConnKit.Host

private final class TerminalHostRepository: HostRepository, @unchecked Sendable {
    var hosts: [Host]

    init(hosts: [Host]) { self.hosts = hosts }

    func allHosts() throws -> [Host] { hosts }
    func host(id: String) throws -> Host? { hosts.first { $0.id == id } }
    func save(_ host: Host) throws { hosts.append(host) }
    func delete(id: String) throws { hosts.removeAll { $0.id == id } }
}

/// `openShell` 被卡住但不响应 Task cancellation，用来复现真实 Citadel 建立 PTY 时
/// 用户删除主机的竞态。只有测试显式 `release()` 后才返回通道。
private actor DelayedShellGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting = false

    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while !waiting {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class DelayedShellTransport: SSHTransport {
    let gate: DelayedShellGate

    init(gate: DelayedShellGate) {
        self.gate = gate
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        _ = (endpoint, username, auth, hostKeyPolicy)
        return DelayedShellSession(gate: gate)
    }
}

private final class DelayedShellSession: SSHSession, @unchecked Sendable {
    private let gate: DelayedShellGate
    private let stateContinuation: AsyncStream<SSHSessionState>.Continuation
    let state: AsyncStream<SSHSessionState>
    private var closed = false

    var isConnected: Bool { !closed }

    init(gate: DelayedShellGate) {
        self.gate = gate
        (state, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        _ = (command, timeout)
        throw SSHError.channelClosed
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = command
        throw SSHError.channelClosed
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        _ = (command, timeout)
        throw SSHError.channelClosed
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        _ = term
        await gate.wait()
        return DelayedShellChannel()
    }

    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        _ = target
        throw SSHError.channelClosed
    }

    func close() async {
        closed = true
        stateContinuation.yield(.closed)
        stateContinuation.finish()
    }
}

private final class DelayedShellChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func write(_ bytes: Data) async throws { _ = bytes }
    func resize(_ size: TermSize) async throws { _ = size }
    func close() async { continuation.finish() }
}

@Suite("TerminalSessionCoordinator — 创建与复用")
@MainActor
struct TerminalSessionCoordinatorTests {
    @Test("普通主机入口复用最近会话，显式新建则创建新 PTY")
    func reusesRecentOrCreatesExplicitNewSession() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let normal = TerminalLaunchRequest(host: host, policy: .reuseRecentOrCreate, source: .shell)

        let first = await coordinator.launch(normal)
        let reused = await coordinator.launch(normal)
        let created = await coordinator.launch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
        )

        guard case let .success(firstTab) = first,
              case let .success(reusedTab) = reused,
              case let .success(createdTab) = created else {
            Issue.record("三个 launch 都应成功")
            return
        }
        #expect(firstTab.id == reusedTab.id)
        #expect(createdTab.id != firstTab.id)
        #expect(coordinator.store.tabs.count == 2)
    }

    @Test("首次连接失败不写入会话中心，且错误只能消费一次")
    func failedFirstLaunchDoesNotCreateTab() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let endpoint = SSHEndpoint(host: host.address, port: host.port)
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(behavior: .init(failConnect: .connectionRefused(endpoint: endpoint)))
            )
        )

        let result = await coordinator.launch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
        )

        guard case let .failure(failure) = result else {
            Issue.record("连接失败应返回 launch failure")
            return
        }
        #expect(coordinator.store.tabs.isEmpty)
        #expect(coordinator.consumeFailure(failure) != nil)
        #expect(coordinator.consumeFailure(failure) == nil)
    }

    @Test("重连保留同一 Tab、替换 PTY 并写入代次边界")
    func reconnectReplacesSessionWithinSameTab() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )

        let launched = await coordinator.launch(
            TerminalLaunchRequest(
                host: host,
                policy: .createNew,
                source: .docker(containerName: "api"),
                initialCommand: "docker exec -it api sh",
                replayInitialCommandOnReconnect: true
            )
        )
        guard case let .success(first) = launched else {
            Issue.record("初次创建应成功")
            return
        }

        let reconnected = await coordinator.reconnect(first.id)
        guard case let .success(second) = reconnected else {
            Issue.record("重连应成功")
            return
        }
        #expect(second.id == first.id)
        #expect(second.generation == first.generation + 1)
        #expect(ObjectIdentifier(second.session) != ObjectIdentifier(first.session))

        let attachment = await second.transcript.attach()
        var iterator = attachment.events.makeAsyncIterator()
        _ = await iterator.next()
        guard case let .replayBytes(bytes)? = await iterator.next() else {
            Issue.record("重连后的回放应保留输出")
            return
        }
        #expect(String(decoding: bytes, as: UTF8.self).contains("[已重新连接]"))
        await coordinator.close(first.id)
    }

    @Test("主机删除在 PTY 建立途中发生时，不得留下孤儿会话")
    func deletingHostWhileShellIsOpeningDoesNotAddATab() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let gate = DelayedShellGate()
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: DelayedShellTransport(gate: gate))
        )

        let launch = Task {
            await coordinator.launch(
                TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
            )
        }
        await gate.waitUntilBlocked()

        await coordinator.closeAll(forHost: host.id)
        await gate.release()

        guard case .failure = await launch.value else {
            Issue.record("删除中的主机完成 PTY 建立后不应再创建会话")
            return
        }
        #expect(coordinator.store.tabs.isEmpty)
    }

    @Test("编辑主机连接身份后，旧终端会话和旧 SSH 连接都会失效")
    func changingHostConnectionIdentityClosesSessionsAndEvictsOldConnection() async {
        let previous = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let updated = Host(id: "host-1", name: "prod-web", address: "10.0.0.2", username: "ops", port: 2222)
        let manager = ConnectionManager(transport: MockSSHTransport())
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [previous]),
            connectionManager: manager
        )

        guard case .success = await coordinator.launch(
            TerminalLaunchRequest(host: previous, policy: .createNew, source: .shell)
        ) else {
            Issue.record("初始终端会话应成功建立")
            return
        }
        #expect(await manager.activeCount == 1)

        await coordinator.hostDidSave(updated, replacing: previous, connectionIdentityChanged: true)

        #expect(coordinator.store.tabs.isEmpty)
        #expect(await manager.activeCount == 0)
    }
}
