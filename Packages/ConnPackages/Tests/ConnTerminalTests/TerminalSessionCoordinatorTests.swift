import ConnKit
import ConnMultiplexer
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
    private var channelClosed = false

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

    func markChannelClosed() {
        channelClosed = true
    }

    func wasChannelClosed() -> Bool {
        channelClosed
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
        return DelayedShellChannel(gate: gate)
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
    private let gate: DelayedShellGate
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(gate: DelayedShellGate) {
        self.gate = gate
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func write(_ bytes: Data) async throws { _ = bytes }
    func resize(_ size: TermSize) async throws { _ = size }
    func close() async {
        await gate.markChannelClosed()
        continuation.finish()
    }
}

private final class LivenessTerminalTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [LivenessTerminalSession] = []

    var latestSession: LivenessTerminalSession? {
        lock.withLock { sessions.last }
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        _ = (endpoint, username, auth, hostKeyPolicy)
        let session = LivenessTerminalSession()
        lock.withLock { sessions.append(session) }
        return session
    }
}

private final class LivenessTerminalSession: SSHSession, @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    private let stateContinuation: AsyncStream<SSHSessionState>.Continuation
    let state: AsyncStream<SSHSessionState>

    var isConnected: Bool { lock.withLock { alive } }

    init() {
        (state, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected)
    }

    func simulateDisconnect() {
        lock.withLock { alive = false }
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
        guard isConnected else { throw SSHError.channelClosed }
        return LivenessTerminalShellChannel()
    }

    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        _ = target
        throw SSHError.channelClosed
    }

    func close() async {
        lock.withLock { alive = false }
        stateContinuation.yield(.closed)
        stateContinuation.finish()
    }
}

private final class LivenessTerminalShellChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func write(_ bytes: Data) async throws { _ = bytes }
    func resize(_ size: TermSize) async throws { _ = size }
    func close() async { continuation.finish() }
}

private actor PersistentRenameRecorder {
    private(set) var values: [String] = []
    private let error: PersistentTerminalError?

    init(error: PersistentTerminalError? = nil) {
        self.error = error
    }

    func rename(workspaceID: String, to name: String) throws {
        values.append("\(workspaceID):\(name)")
        if let error { throw error }
    }
}

private struct RenamePlatformDetector: RemotePlatformDetecting {
    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        RemotePlatformProfile(kind: .linux, shell: .sh)
    }
}

private struct RenamePersistentProvider: PersistentTerminalProvider, Sendable {
    let descriptor: PersistentTerminalProviderDescriptor
    let defaultConfiguration: PersistentTerminalConfiguration
    let attachmentDescriptor: PersistentAttachmentDescriptor
    let recorder: PersistentRenameRecorder

    init(recorder: PersistentRenameRecorder) {
        self.recorder = recorder
        descriptor = PersistentTerminalProviderDescriptor(
            id: "rename-test",
            displayName: "Rename test",
            supportedPlatforms: [.linux],
            supportedConfigurationVersions: [1],
            supportedWorkspaceInstancePayloadVersions: [1],
            supportedAttachmentPayloadVersions: [1],
            potentialFeatures: [.workspaceRename]
        )
        defaultConfiguration = PersistentTerminalConfiguration(
            providerID: "rename-test",
            configurationKey: "default",
            payloadVersion: 1,
            providerPayload: Data()
        )
        attachmentDescriptor = PersistentAttachmentDescriptor(
            providerID: "rename-test",
            configuration: defaultConfiguration,
            workspace: RemoteWorkspaceRef(
                workspaceID: "$1",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        )
    }

    func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
        .init(state: .available, effectiveFeatures: [.workspaceRename])
    }

    func listWorkspaces(
        in context: PersistentTerminalContext
    ) async throws -> [RemoteWorkspaceSummary] { [] }

    func createWorkspace(
        _ request: CreateWorkspaceRequest,
        in context: PersistentTerminalContext
    ) async throws -> RemoteWorkspaceSummary {
        .init(
            workspace: attachmentDescriptor.workspace,
            name: request.name ?? "ops",
            occupancy: .init(
                affectedAttachmentCount: nil,
                observedAt: .now,
                freshness: .fresh
            )
        )
    }

    func renameWorkspace(
        _ workspace: RemoteWorkspaceRef,
        to newName: String,
        in context: PersistentTerminalContext
    ) async throws {
        try await recorder.rename(workspaceID: workspace.workspaceID, to: newName)
    }

    func destroyWorkspace(
        _ workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) async throws {}

    func makeAttachmentDescriptor(
        to workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) throws -> PersistentAttachmentDescriptor {
        PersistentAttachmentDescriptor(
            providerID: descriptor.id,
            configuration: context.backendConfiguration,
            workspace: workspace,
            payloadVersion: 1,
            providerPayload: Data()
        )
    }

    func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment {
        throw PersistentTerminalError.unsupportedFeature(
            providerID: self.descriptor.id,
            feature: "open"
        )
    }
}

private func makePersistentRenameTab(
    host: Host,
    descriptor: PersistentAttachmentDescriptor
) -> TerminalTab {
    TerminalTab(
        hostID: host.id,
        hostName: host.name,
        hostAddress: host.displayAddress,
        session: TerminalSession(channel: LivenessTerminalShellChannel()),
        source: .persistent(providerID: descriptor.providerID),
        reconnectDescriptor: .persistent(descriptor),
        automaticAlias: "ops"
    )
}

private actor RecoveryAttachmentRecorder {
    private(set) var reasons: [PersistentAttachmentOpenReason] = []
    private(set) var attachments: [RecoveryAttachment] = []
    private let failOnOpenNumbers: Set<Int>

    init(failOnOpenNumbers: Set<Int> = []) {
        self.failOnOpenNumbers = failOnOpenNumbers
    }

    func open(
        descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason
    ) -> RecoveryAttachment {
        let attachment = RecoveryAttachment(descriptor: descriptor)
        reasons.append(reason)
        attachments.append(attachment)
        if failOnOpenNumbers.contains(reasons.count) {
            attachment.fail(recovery: .rebuildAttachment)
        }
        return attachment
    }
}

private final class RecoveryAttachment: PersistentTerminalAttachment, @unchecked Sendable {
    let descriptor: PersistentAttachmentDescriptor
    let presentation: PersistentAttachmentPresentation
    let lifecycleEvents: AsyncStream<PersistentTerminalAttachmentLifecycleEvent>
    private let continuation: AsyncStream<PersistentTerminalAttachmentLifecycleEvent>.Continuation
    private let channel = LivenessTerminalShellChannel()
    private let lock = NSLock()
    private var didClose = false

    init(descriptor: PersistentAttachmentDescriptor) {
        self.descriptor = descriptor
        presentation = .byteTerminal(channel)
        (lifecycleEvents, continuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func fail(recovery: PersistentTerminalAttachmentRecovery) {
        continuation.yield(.failed(.init(
            componentID: "test.control-plane",
            issue: .transportClosed,
            recovery: recovery
        )))
    }

    func close() async {
        guard lock.withLock({
            guard !didClose else { return false }
            didClose = true
            return true
        }) else { return }
        continuation.finish()
        await channel.close()
    }
}

private struct RecoveryPersistentProvider: PersistentTerminalProvider, Sendable {
    let descriptor = PersistentTerminalProviderDescriptor(
        id: "recovery-test",
        displayName: "Recovery test",
        supportedPlatforms: [.linux],
        supportedConfigurationVersions: [1],
        supportedWorkspaceInstancePayloadVersions: [1],
        supportedAttachmentPayloadVersions: [1],
        potentialFeatures: []
    )
    let defaultConfiguration = PersistentTerminalConfiguration(
        providerID: "recovery-test",
        configurationKey: "default",
        payloadVersion: 1,
        providerPayload: Data()
    )
    let recorder: RecoveryAttachmentRecorder

    var attachmentDescriptor: PersistentAttachmentDescriptor {
        PersistentAttachmentDescriptor(
            providerID: descriptor.id,
            configuration: defaultConfiguration,
            workspace: .init(
                workspaceID: "workspace-1",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        )
    }

    func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
        .init(state: .available, effectiveFeatures: [])
    }

    func listWorkspaces(
        in context: PersistentTerminalContext
    ) async throws -> [RemoteWorkspaceSummary] { [] }

    func createWorkspace(
        _ request: CreateWorkspaceRequest,
        in context: PersistentTerminalContext
    ) async throws -> RemoteWorkspaceSummary {
        throw PersistentTerminalError.unsupportedFeature(
            providerID: descriptor.id,
            feature: "create"
        )
    }

    func renameWorkspace(
        _ workspace: RemoteWorkspaceRef,
        to newName: String,
        in context: PersistentTerminalContext
    ) async throws {}

    func destroyWorkspace(
        _ workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) async throws {}

    func makeAttachmentDescriptor(
        to workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) throws -> PersistentAttachmentDescriptor {
        attachmentDescriptor
    }

    func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment {
        await recorder.open(descriptor: descriptor, reason: reason)
    }
}

@Suite("TerminalSessionCoordinator — 创建与复用", .serialized)
@MainActor
struct TerminalSessionCoordinatorTests {
    @Test("launch attempt 只有 commit 后才把 Tab 加入 Store")
    func launchAttemptAddsTabOnlyAfterCommit() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let attemptID = coordinator.beginLaunchAttempt()

        let prepared = await coordinator.prepareLaunch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell),
            attemptID: attemptID
        )

        guard case .success = prepared else {
            Issue.record("prepare 应成功")
            return
        }
        #expect(coordinator.store.tabs.isEmpty)

        let committed = await coordinator.commitLaunch(attemptID: attemptID)

        guard case let .success(tab) = committed else {
            Issue.record("commit 应成功")
            return
        }
        #expect(coordinator.store.tabs.map(\.id) == [tab.id])
        #expect(coordinator.store.currentTabID == tab.id)
        await coordinator.close(tab.id)
    }

    @Test("launch attempt 在 prepare 开始前取消后不能创建 Tab")
    func cancellingLaunchAttemptBeforePreparePreventsTabCreation() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let attemptID = coordinator.beginLaunchAttempt()

        await coordinator.cancelLaunch(attemptID: attemptID)
        let prepared = await coordinator.prepareLaunch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell),
            attemptID: attemptID
        )
        let committed = await coordinator.commitLaunch(attemptID: attemptID)

        guard case .failure = prepared, case .failure = committed else {
            Issue.record("取消的 attempt 不得 prepare 或 commit")
            return
        }
        #expect(coordinator.store.tabs.isEmpty)
    }

    @Test("launch attempt 在不可取消的 PTY open 中取消会关闭迟到通道")
    func cancellingLaunchAttemptDuringNonCancellableOpenClosesLateChannel() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let gate = DelayedShellGate()
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: DelayedShellTransport(gate: gate))
        )
        let attemptID = coordinator.beginLaunchAttempt()
        let prepare = Task {
            await coordinator.prepareLaunch(
                TerminalLaunchRequest(host: host, policy: .createNew, source: .shell),
                attemptID: attemptID
            )
        }
        await gate.waitUntilBlocked()

        await coordinator.cancelLaunch(attemptID: attemptID)
        await gate.release()

        guard case .failure = await prepare.value else {
            Issue.record("迟到的 open 结果必须被取消")
            return
        }
        #expect(coordinator.store.tabs.isEmpty)
        #expect(await gate.wasChannelClosed())
    }

    @Test("主机失效会取消已 prepare 但尚未 commit 的 launch attempt")
    func invalidatingHostCancelsPreparedLaunchAttempt() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let attemptID = coordinator.beginLaunchAttempt()
        let prepared = await coordinator.prepareLaunch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell),
            attemptID: attemptID
        )
        guard case .success = prepared else {
            Issue.record("prepare 应成功")
            return
        }

        await coordinator.closeAll(forHost: host.id)
        let committed = await coordinator.commitLaunch(attemptID: attemptID)

        guard case .failure = committed else {
            Issue.record("主机失效后的 attempt 不得 commit")
            return
        }
        #expect(coordinator.store.tabs.isEmpty)
    }

    @Test("取消已 prepare 的 launch attempt 后不能再 commit")
    func cancellingPreparedLaunchAttemptPreventsCommit() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let attemptID = coordinator.beginLaunchAttempt()
        guard case .success = await coordinator.prepareLaunch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell),
            attemptID: attemptID
        ) else {
            Issue.record("prepare 应成功")
            return
        }

        await coordinator.cancelLaunch(attemptID: attemptID)

        guard case .failure = await coordinator.commitLaunch(attemptID: attemptID) else {
            Issue.record("取消后不得 commit")
            return
        }
        #expect(coordinator.store.tabs.isEmpty)
    }

    @Test("取消已 prepare 的 launch attempt 会关闭临时通道")
    func cancellingPreparedLaunchAttemptClosesTemporaryChannel() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let gate = DelayedShellGate()
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: DelayedShellTransport(gate: gate))
        )
        let attemptID = coordinator.beginLaunchAttempt()
        let preparation = Task {
            await coordinator.prepareLaunch(
                TerminalLaunchRequest(host: host, policy: .createNew, source: .shell),
                attemptID: attemptID
            )
        }
        await gate.waitUntilBlocked()
        await gate.release()
        guard case .success = await preparation.value else {
            Issue.record("prepare 应成功")
            return
        }

        await coordinator.cancelLaunch(attemptID: attemptID)

        #expect(coordinator.store.tabs.isEmpty)
        #expect(await gate.wasChannelClosed())
    }

    @Test("未知或已消费的 launch attempt 不能重复 prepare/commit")
    func unknownAndConsumedLaunchAttemptsAreRejected() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let request = TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
        let unknown = TerminalLaunchAttemptID(rawValue: UUID())
        guard case .failure = await coordinator.prepareLaunch(request, attemptID: unknown),
              case .failure = await coordinator.commitLaunch(attemptID: unknown)
        else {
            Issue.record("未知 attempt 必须被拒绝")
            return
        }

        let consumed = coordinator.beginLaunchAttempt()
        guard case .success = await coordinator.prepareLaunch(request, attemptID: consumed),
              case let .success(tab) = await coordinator.commitLaunch(attemptID: consumed),
              case .failure = await coordinator.prepareLaunch(request, attemptID: consumed),
              case .failure = await coordinator.commitLaunch(attemptID: consumed)
        else {
            Issue.record("已消费 attempt 不得复用")
            return
        }
        await coordinator.close(tab.id)
    }

    @Test("commit 成功后取消同一 attempt 不关闭已归属 Store 的 Tab")
    func cancellingConsumedLaunchAttemptKeepsCommittedTab() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let attemptID = coordinator.beginLaunchAttempt()
        guard case .success = await coordinator.prepareLaunch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell),
            attemptID: attemptID
        ), case let .success(tab) = await coordinator.commitLaunch(attemptID: attemptID) else {
            Issue.record("launch transaction 应成功")
            return
        }

        await coordinator.cancelLaunch(attemptID: attemptID)

        #expect(coordinator.store.tab(id: tab.id) != nil)
        await coordinator.close(tab.id)
    }

    @Test("持久终端来源始终取 descriptor 的真实 provider")
    func persistentBackendNormalizesDisplayedSource() {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let descriptor = PersistentAttachmentDescriptor(
            providerID: "tmux",
            configuration: PersistentTerminalConfiguration(
                providerID: "tmux",
                configurationKey: "default",
                payloadVersion: 1,
                providerPayload: Data()
            ),
            workspace: RemoteWorkspaceRef(
                workspaceID: "$1",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        )

        let request = TerminalLaunchRequest(
            host: host,
            policy: .createNew,
            source: .shell,
            backend: .persistent(descriptor)
        )

        #expect(request.source == .persistent(providerID: "tmux"))
    }

    @Test("普通 PTY 不能保留持久终端来源")
    func plainPTYRejectsPersistentDisplayedSource() {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")

        let request = TerminalLaunchRequest(
            host: host,
            policy: .createNew,
            source: .persistent(providerID: "tmux"),
            backend: .plainPTY
        )

        #expect(request.source == .shell)
    }

    @Test("持久终端成功启动后保存恢复记录，普通 PTY 不保存")
    func persistsOnlySuccessfulPersistentTerminals() async throws {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let repository = InMemoryTerminalResumeRepository()
        let recorder = RecoveryAttachmentRecorder()
        let provider = RecoveryPersistentProvider(recorder: recorder)
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(),
                platformDetector: RenamePlatformDetector()
            ),
            providerRegistry: try PersistentTerminalProviderRegistry(providers: [provider]),
            resumeRepository: repository
        )

        guard case let .success(persistentTab) = await coordinator.launch(.init(
            host: host,
            policy: .createNew,
            source: .persistent(providerID: provider.descriptor.id),
            backend: .persistent(provider.attachmentDescriptor),
            automaticAlias: "ops"
        )) else {
            Issue.record("持久终端应启动成功")
            return
        }
        guard case let .success(plainTab) = await coordinator.launch(.init(
            host: host,
            policy: .createNew,
            source: .shell
        )) else {
            Issue.record("普通 PTY 应启动成功")
            return
        }

        let records = try repository.allRecords()
        #expect(records.count == 1)
        #expect(records.first?.id == persistentTab.id)
        #expect(records.first?.displayName == "ops")
        #expect(records.first?.descriptor == provider.attachmentDescriptor)

        await coordinator.close(plainTab.id)
        #expect(try repository.allRecords().count == 1)
        await coordinator.close(persistentTab.id)
        #expect(try repository.allRecords().isEmpty)
    }

    @Test("App 重启后直接用保存的 descriptor 恢复并在主动关闭时删除记录")
    func restoresPersistedTerminalWithoutWorkspaceDiscovery() async throws {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = RecoveryAttachmentRecorder()
        let provider = RecoveryPersistentProvider(recorder: recorder)
        let record = PersistentTerminalResumeRecord(
            id: "resume-1",
            hostID: host.id,
            hostName: host.name,
            hostAddress: host.displayAddress,
            descriptor: provider.attachmentDescriptor,
            automaticAlias: "ops",
            createdAt: Date(timeIntervalSince1970: 1),
            lastConnectedAt: Date(timeIntervalSince1970: 2)
        )
        let repository = InMemoryTerminalResumeRepository(records: [record])
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(),
                platformDetector: RenamePlatformDetector()
            ),
            providerRegistry: try PersistentTerminalProviderRegistry(providers: [provider]),
            resumeRepository: repository
        )

        #expect(coordinator.store.tabs.isEmpty)
        #expect(coordinator.store.hostGroups.first?.resumeRecords == [record])

        guard case let .success(tab) = await coordinator.restore(record.id) else {
            Issue.record("保存的持久终端应恢复成功")
            return
        }

        #expect(tab.id == record.id)
        #expect(tab.displayName == "ops")
        #expect(await recorder.reasons == [.reconnect])
        #expect(coordinator.store.hostGroups.first?.resumeRecords.isEmpty == true)
        #expect(coordinator.store.hostGroups.first?.tabs.map(\.id) == [record.id])

        await coordinator.close(tab.id)
        #expect(try repository.allRecords().isEmpty)
        #expect(coordinator.store.hostGroups.isEmpty)
    }

    @Test("连接中断只标记断开，不删除持久终端恢复记录")
    func transientAttachmentFailureKeepsResumeRecord() async throws {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = RecoveryAttachmentRecorder()
        let provider = RecoveryPersistentProvider(recorder: recorder)
        let repository = InMemoryTerminalResumeRepository()
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(),
                platformDetector: RenamePlatformDetector()
            ),
            providerRegistry: try PersistentTerminalProviderRegistry(providers: [provider]),
            resumeRepository: repository
        )

        guard case let .success(tab) = await coordinator.launch(.init(
            host: host,
            policy: .createNew,
            source: .persistent(providerID: provider.descriptor.id),
            backend: .persistent(provider.attachmentDescriptor),
            automaticAlias: "ops"
        )) else {
            Issue.record("持久终端应启动成功")
            return
        }
        let attachment = try #require(await recorder.attachments.first)
        attachment.fail(recovery: .manual)
        for _ in 0 ..< 50 {
            if case .disconnected = coordinator.store.tab(id: tab.id)?.status { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .disconnected = coordinator.store.tab(id: tab.id)?.status else {
            Issue.record("连接故障应保留 Tab 并标记为断开")
            return
        }
        #expect(try repository.allRecords().map(\.id) == [tab.id])

        await coordinator.close(tab.id)
        #expect(try repository.allRecords().isEmpty)
    }

    @Test("主机连接身份变化会清理旧持久终端恢复记录")
    func changingHostIdentityRemovesResumeRecords() async throws {
        let previous = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let updated = Host(id: "host-1", name: "web", address: "10.0.0.2", username: "root")
        let recorder = RecoveryAttachmentRecorder()
        let provider = RecoveryPersistentProvider(recorder: recorder)
        let repository = InMemoryTerminalResumeRepository(records: [
            PersistentTerminalResumeRecord(
                id: "resume-1",
                hostID: previous.id,
                hostName: previous.name,
                hostAddress: previous.displayAddress,
                descriptor: provider.attachmentDescriptor,
                automaticAlias: "ops"
            ),
        ])
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [previous]),
            connectionManager: ConnectionManager(transport: MockSSHTransport()),
            resumeRepository: repository
        )

        await coordinator.hostDidSave(updated, replacing: previous, connectionIdentityChanged: true)

        #expect(try repository.allRecords().isEmpty)
        #expect(coordinator.store.hostGroups.isEmpty)
    }

    @Test("启动请求提供的 Workspace 名称成为终端自动别名")
    func launchUsesRequestedAutomaticAlias() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )

        let result = await coordinator.launch(TerminalLaunchRequest(
            host: host,
            policy: .createNew,
            source: .shell,
            automaticAlias: "ops"
        ))

        guard case let .success(tab) = result else {
            Issue.record("终端应创建成功")
            return
        }
        #expect(tab.automaticAlias == "ops")
        #expect(tab.displayName == "ops")
        await coordinator.close(tab.id)
    }

    @Test("持久终端重命名成功后才同步本地名称")
    func persistentRenameUpdatesRemoteBeforeLocalName() async throws {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = PersistentRenameRecorder()
        let provider = RenamePersistentProvider(recorder: recorder)
        let repository = InMemoryTerminalResumeRepository()
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(),
                platformDetector: RenamePlatformDetector()
            ),
            providerRegistry: try PersistentTerminalProviderRegistry(providers: [provider]),
            resumeRepository: repository
        )
        let tab = makePersistentRenameTab(host: host, descriptor: provider.attachmentDescriptor)
        coordinator.store.add(tab)

        let result = await coordinator.rename(tab.id, to: "  production  ")

        guard case let .success(updated) = result else {
            Issue.record("重命名应成功")
            return
        }
        #expect(await recorder.values == ["$1:production"])
        #expect(updated.automaticAlias == "production")
        #expect(updated.alias == nil)
        #expect(updated.displayName == "production")
        #expect(try repository.allRecords().first?.displayName == "production")
    }

    @Test("持久终端远端重命名失败时保留本地名称")
    func failedPersistentRenameKeepsLocalName() async throws {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = PersistentRenameRecorder(error: .transportClosed)
        let provider = RenamePersistentProvider(recorder: recorder)
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(),
                platformDetector: RenamePlatformDetector()
            ),
            providerRegistry: try PersistentTerminalProviderRegistry(providers: [provider])
        )
        let tab = makePersistentRenameTab(host: host, descriptor: provider.attachmentDescriptor)
        coordinator.store.add(tab)

        let result = await coordinator.rename(tab.id, to: "production")

        guard case .failure = result else {
            Issue.record("远端失败必须返回失败")
            return
        }
        #expect(coordinator.store.tab(id: tab.id)?.displayName == "ops")
        #expect(coordinator.store.tab(id: tab.id)?.automaticAlias == "ops")
    }

    @Test("持久终端清空别名只恢复 Session 自动名称且不修改远端")
    func clearingPersistentAliasDoesNotRenameRemote() async throws {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = PersistentRenameRecorder()
        let provider = RenamePersistentProvider(recorder: recorder)
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(),
                platformDetector: RenamePlatformDetector()
            ),
            providerRegistry: try PersistentTerminalProviderRegistry(providers: [provider])
        )
        var tab = makePersistentRenameTab(host: host, descriptor: provider.attachmentDescriptor)
        tab.alias = "临时名称"
        coordinator.store.add(tab)

        let result = await coordinator.rename(tab.id, to: "   ")

        guard case let .success(updated) = result else {
            Issue.record("清空本地覆盖应成功")
            return
        }
        #expect(await recorder.values.isEmpty)
        #expect(updated.alias == nil)
        #expect(updated.displayName == "ops")
    }

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
        await first.transcript.activateGeneration(first.generation)
        await first.transcript.append(Array("old-screen\n".utf8), generation: first.generation)

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
        #expect(!String(decoding: bytes, as: UTF8.self).contains("old-screen"))
        #expect(String(decoding: bytes, as: UTF8.self).contains("[已重新连接]"))
        await coordinator.close(first.id)
    }

    @Test("必需组件连续失效时每一代都用同一 descriptor 和启动流水线重建")
    func requiredAttachmentFailureRebuildsThroughReconnectPipeline() async throws {
        let host = Host(
            id: "host-1",
            name: "web",
            address: "10.0.0.1",
            username: "root"
        )
        // The second attachment fails before its lifecycle observer is installed. Its
        // buffered failure must supersede (not be erased by) the first recovery task.
        let recorder = RecoveryAttachmentRecorder(failOnOpenNumbers: [2])
        let provider = RecoveryPersistentProvider(recorder: recorder)
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(),
                platformDetector: RenamePlatformDetector()
            ),
            providerRegistry: try PersistentTerminalProviderRegistry(providers: [provider])
        )

        guard case let .success(first) = await coordinator.launch(.init(
            host: host,
            policy: .createNew,
            source: .persistent(providerID: provider.descriptor.id),
            backend: .persistent(provider.attachmentDescriptor),
            automaticAlias: "workspace-1"
        )) else {
            Issue.record("初次 persistent attachment 应成功")
            return
        }
        let firstAttachment = try #require(await recorder.attachments.first)
        firstAttachment.fail(recovery: .rebuildAttachment)

        for _ in 0 ..< 100 {
            if await recorder.reasons.count >= 3,
               coordinator.store.tab(id: first.id)?.generation == first.generation + 2,
               coordinator.store.tab(id: first.id)?.status == .connected
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await recorder.reasons == [.initial, .reconnect, .reconnect])
        let rebuilt = try #require(coordinator.store.tab(id: first.id))
        #expect(rebuilt.generation == first.generation + 2)
        #expect(rebuilt.status == .connected)
        #expect(rebuilt.reconnectDescriptor == .persistent(provider.attachmentDescriptor))
        await coordinator.close(first.id)
    }

    @Test("健康终端从后台返回时保持原 generation")
    func backgroundResumePreservesHealthySession() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )

        guard case let .success(first) = await coordinator.launch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
        ) else {
            Issue.record("初次创建应成功")
            return
        }

        await coordinator.resumeAfterBackground(idleFor: 31)

        guard let resumed = coordinator.store.tab(id: first.id) else {
            Issue.record("后台恢复不应移除会话")
            return
        }
        #expect(resumed.generation == first.generation)
        #expect(resumed.status == .connected)
    }

    @Test("已断开的终端从后台返回时恢复")
    func backgroundResumeRecoversDisconnectedSession() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )

        guard case let .success(first) = await coordinator.launch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
        ) else {
            Issue.record("初次创建应成功")
            return
        }
        coordinator.store.updateStatus(first.id, to: .disconnected(message: nil))

        await coordinator.resumeAfterBackground(idleFor: 31)

        #expect(coordinator.store.tab(id: first.id)?.generation == first.generation + 1)
        #expect(coordinator.store.tab(id: first.id)?.status == .connected)
    }

    @Test("连接池确认死亡时恢复仍显示 connected 的终端")
    func backgroundResumeRecoversAffirmativelyDeadTransport() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let transport = LivenessTerminalTransport()
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [host]),
            connectionManager: ConnectionManager(transport: transport)
        )

        guard case let .success(first) = await coordinator.launch(
            TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
        ) else {
            Issue.record("初次创建应成功")
            return
        }
        guard let session = transport.latestSession else {
            Issue.record("transport 应记录创建的池化会话")
            return
        }
        session.simulateDisconnect()

        await coordinator.resumeAfterBackground(idleFor: 31)

        #expect(coordinator.store.tab(id: first.id)?.generation == first.generation + 1)
        #expect(coordinator.store.tab(id: first.id)?.status == .connected)
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

    @Test("仅修改主机展示信息时保留会话端点并刷新名称")
    func savingHostMetadataDoesNotRebuildDisplayAddress() async {
        let previous = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let updated = Host(id: previous.id, name: "生产 Web", address: previous.address, username: previous.username)
        let coordinator = TerminalSessionCoordinator(
            hostRepository: TerminalHostRepository(hosts: [previous]),
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )

        guard case let .success(tab) = await coordinator.launch(
            TerminalLaunchRequest(host: previous, policy: .createNew, source: .shell)
        ) else {
            Issue.record("初始终端会话应成功建立")
            return
        }
        let originalAddress = coordinator.store.currentTab?.hostAddress

        await coordinator.hostDidSave(updated, replacing: previous, connectionIdentityChanged: false)

        #expect(coordinator.store.currentTab?.hostName == "生产 Web")
        #expect(coordinator.store.currentTab?.hostAddress == originalAddress)
        #expect(coordinator.store.tabs.count == 1)
        await coordinator.close(tab.id)
    }

}
