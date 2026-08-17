import ConnKit
import ConnMultiplexer
import ConnSSH
import ConnUI
import Foundation
import Observation

public enum TerminalLaunchPolicy: Sendable, Equatable {
    case reuseRecentOrCreate
    case createNew
    case existing(tabID: String)
}

/// Provider-neutral terminal backend selection. The coordinator only knows how to
/// open a byte presentation; provider identity and payload stay inside the generic
/// descriptor and registry.
public enum TerminalLaunchBackend: Sendable, Equatable {
    case plainPTY
    case persistent(PersistentAttachmentDescriptor)
}

public struct TerminalLaunchRequest: Sendable {
    public let host: ConnKit.Host
    public let policy: TerminalLaunchPolicy
    public let source: TerminalSessionSource
    public let backend: TerminalLaunchBackend
    public let automaticAlias: String?
    public let initialCommand: String?
    public let replayInitialCommandOnReconnect: Bool

    public init(
        host: ConnKit.Host,
        policy: TerminalLaunchPolicy,
        source: TerminalSessionSource,
        backend: TerminalLaunchBackend = .plainPTY,
        automaticAlias: String? = nil,
        initialCommand: String? = nil,
        replayInitialCommandOnReconnect: Bool = false
    ) {
        self.host = host
        self.policy = policy
        self.backend = backend
        self.automaticAlias = automaticAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.source = switch backend {
        case .plainPTY:
            switch source {
            case .persistent:
                .shell
            default:
                source
            }
        case let .persistent(descriptor):
            .persistent(providerID: descriptor.providerID)
        }
        self.initialCommand = initialCommand
        self.replayInitialCommandOnReconnect = replayInitialCommandOnReconnect
    }
}

public struct TerminalLaunchFailure: Error, Sendable, Equatable {
    public let id: UUID
    public let message: String

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

/// A coordinator-owned creation transaction. Callers register it synchronously,
/// prepare temporary resources asynchronously, then explicitly transfer ownership
/// to the local session store by committing it.
public struct TerminalLaunchAttemptID: Hashable, Sendable {
    fileprivate let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// App 全局唯一的多终端编排器。
///
/// 只开关 PTY，不关闭 ConnectionManager 池里的 SSH 连接；监控、文件、Docker 和其它
/// 终端可以持续复用同一连接。会话本身在进程内存中保存，App 被杀后自然消失。
@Observable
@MainActor
public final class TerminalSessionCoordinator {
    public let store = TerminalSessionStore()

    private let hostRepository: any HostRepository
    private let connectionManager: ConnectionManager
    private let persistentBackend: PersistentProviderBackend
    private var inFlightLaunches: [String: Task<Result<TerminalTab, TerminalLaunchFailure>, Never>] = [:]
    /// 主机删除/连接身份变更时递增。Citadel 的建连与开 PTY 不一定响应 cancellation，
    /// 所以必须在完成后再用这个代次阻止旧任务把会话写回 store。
    private var hostLaunchGenerations: [String: UInt64] = [:]
    private var reconnectTasks: [String: Task<Result<TerminalTab, TerminalLaunchFailure>, Never>] = [:]
    private var lifecycleTasks: [String: Task<Void, Never>] = [:]
    private var attachmentLifecycleTasks: [String: Task<Void, Never>] = [:]
    private var automaticRecoveryTasks: [String: AutomaticRecoveryTask] = [:]
    private var consumedFailureIDs: Set<UUID> = []
    private var launchAttempts: [TerminalLaunchAttemptID: LaunchAttemptState] = [:]

    private struct PreparedLaunch {
        let tab: TerminalTab
    }

    private struct AutomaticRecoveryTask {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private enum LaunchAttemptState {
        case pending
        case preparing(hostID: String, hostGeneration: UInt64)
        case prepared(PreparedLaunch)
        case cancelled(workerOutstanding: Bool)
    }

    public init(
        hostRepository: any HostRepository,
        connectionManager: ConnectionManager,
        providerRegistry: PersistentTerminalProviderRegistry = .default
    ) {
        self.hostRepository = hostRepository
        self.connectionManager = connectionManager
        persistentBackend = PersistentProviderBackend(registry: providerRegistry)
    }

    public func launch(_ request: TerminalLaunchRequest) async -> Result<TerminalTab, TerminalLaunchFailure> {
        switch request.policy {
        case let .existing(tabID):
            guard let tab = store.tab(id: tabID) else {
                return .failure(TerminalLaunchFailure(message: L("终端会话不存在")))
            }
            store.select(tabID)
            return .success(tab)

        case .reuseRecentOrCreate:
            if let existing = store.recentTab(forHost: request.host.id) {
                store.select(existing.id)
                return .success(existing)
            }

            let key = request.host.id
            if let task = inFlightLaunches[key] {
                return await task.value
            }
            let task: Task<Result<TerminalTab, TerminalLaunchFailure>, Never> = Task { [weak self] in
                guard let self else {
                    return Result.failure(TerminalLaunchFailure(message: L("终端协调器已释放")))
                }
                return await self.launchNew(request)
            }
            inFlightLaunches[key] = task
            let result = await task.value
            if inFlightLaunches[key] == task {
                inFlightLaunches[key] = nil
            }
            return result

        case .createNew:
            return await launchNew(request)
        }
    }

    /// Registers the cancellation boundary before the caller starts asynchronous work.
    public func beginLaunchAttempt() -> TerminalLaunchAttemptID {
        let attemptID = TerminalLaunchAttemptID(rawValue: UUID())
        launchAttempts[attemptID] = .pending
        return attemptID
    }

    /// Opens and configures a temporary terminal without exposing it through the Store.
    public func prepareLaunch(
        _ request: TerminalLaunchRequest,
        attemptID: TerminalLaunchAttemptID
    ) async -> Result<Void, TerminalLaunchFailure> {
        switch launchAttempts[attemptID] {
        case .pending:
            break
        case .cancelled:
            // A caller can close the sheet after synchronously registering the
            // attempt but before this worker gets its first executor turn.
            launchAttempts[attemptID] = nil
            return .failure(TerminalLaunchFailure(message: L("终端会话启动已取消")))
        case .preparing, .prepared, .none:
            return .failure(TerminalLaunchFailure(message: L("终端会话启动已取消")))
        }
        let hostGeneration = launchGeneration(forHost: request.host.id)
        launchAttempts[attemptID] = .preparing(
            hostID: request.host.id,
            hostGeneration: hostGeneration
        )

        switch await prepareTab(
            for: request,
            expectedHostLaunchGeneration: hostGeneration
        ) {
        case let .success(prepared):
            guard case .preparing? = launchAttempts[attemptID] else {
                await closePreparedLaunch(prepared)
                if case .cancelled? = launchAttempts[attemptID] {
                    launchAttempts[attemptID] = nil
                }
                return .failure(TerminalLaunchFailure(message: L("终端会话启动已取消")))
            }
            launchAttempts[attemptID] = .prepared(prepared)
            return .success(())
        case let .failure(failure):
            launchAttempts[attemptID] = nil
            return .failure(failure)
        }
    }

    /// Transfers a prepared terminal to the Store. This is the only transaction step
    /// that makes the tab visible and starts its lifecycle observation.
    public func commitLaunch(
        attemptID: TerminalLaunchAttemptID
    ) async -> Result<TerminalTab, TerminalLaunchFailure> {
        guard case let .prepared(prepared)? = launchAttempts.removeValue(forKey: attemptID) else {
            return .failure(TerminalLaunchFailure(message: L("终端会话启动已取消")))
        }
        let tab = prepared.tab
        store.add(tab)
        await tab.session.start()
        observeLifecycle(for: tab.id, generation: tab.generation, session: tab.session)
        observeAttachmentLifecycle(
            for: tab.id,
            generation: tab.generation,
            attachment: tab.persistentAttachment
        )
        return .success(tab)
    }

    /// Cancels ownership transfer. A preparing attempt keeps a tombstone until its
    /// worker returns and closes any resources produced by a non-cancellable open.
    public func cancelLaunch(attemptID: TerminalLaunchAttemptID) async {
        switch launchAttempts[attemptID] {
        case .pending, .preparing:
            launchAttempts[attemptID] = .cancelled(workerOutstanding: true)
        case let .prepared(prepared):
            launchAttempts[attemptID] = .cancelled(workerOutstanding: false)
            await closePreparedLaunch(prepared)
            if case .cancelled(workerOutstanding: false)? = launchAttempts[attemptID] {
                launchAttempts[attemptID] = nil
            }
        case .cancelled, .none:
            break
        }
    }

    /// 同一失败 ID 最多由一个展示层消费，从而避免并发入口重复 Toast。
    public func consumeFailure(_ failure: TerminalLaunchFailure) -> String? {
        guard consumedFailureIDs.insert(failure.id).inserted else { return nil }
        return failure.message
    }

    /// Startup UI queries provider capabilities through the generic backend. A
    /// missing/unsupported provider returns an unavailable candidate; plain PTY
    /// remains the caller's safe default.
    public func persistentBackendOptions() -> [PersistentBackendOption] {
        persistentBackend.options()
    }

    public func makePersistentBackend(
        from option: PersistentBackendOption,
        for host: ConnKit.Host
    ) async throws -> PersistentTerminalLaunch {
        try await persistentBackend.defaultLaunch(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
    }

    public func persistentWorkspaceOptions(
        for option: PersistentBackendOption,
        host: ConnKit.Host
    ) async throws -> [RemoteWorkspaceSummary] {
        return try await persistentBackend.workspaceOptions(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
    }

    public func makePersistentBackend(
        from option: PersistentBackendOption,
        workspace: RemoteWorkspaceSummary,
        for host: ConnKit.Host
    ) async throws -> PersistentTerminalLaunch {
        try await persistentBackend.launch(
            for: workspace,
            option: option,
            host: host,
            connectionManager: connectionManager
        )
    }

    public func makePersistentBackend(
        from option: PersistentBackendOption,
        create selection: PersistentWorkspaceCreateSelection,
        for host: ConnKit.Host
    ) async throws -> PersistentTerminalLaunch {
        try await persistentBackend.createLaunch(
            for: selection,
            option: option,
            host: host,
            connectionManager: connectionManager
        )
    }

    public func openPersistentCatalog(
        for option: PersistentBackendOption,
        host: ConnKit.Host
    ) async throws -> any PersistentTerminalCatalogAttachment {
        return try await persistentBackend.openCatalog(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
    }

    public func makePersistentAttachmentDescriptor(
        for workspace: RemoteWorkspaceRef,
        option: PersistentBackendOption,
        host: ConnKit.Host
    ) async throws -> PersistentAttachmentDescriptor {
        return try await persistentBackend.descriptor(
            for: workspace,
            option: option,
            host: host,
            connectionManager: connectionManager
        )
    }

    public func reconnect(_ tabID: String) async -> Result<TerminalTab, TerminalLaunchFailure> {
        if let task = reconnectTasks[tabID] {
            return await task.value
        }
        let task: Task<Result<TerminalTab, TerminalLaunchFailure>, Never> = Task { [weak self] in
            guard let self else {
                return Result.failure(TerminalLaunchFailure(message: L("终端协调器已释放")))
            }
            return await self.replaceDisconnectedTab(tabID)
        }
        reconnectTasks[tabID] = task
        let result = await task.value
        if reconnectTasks[tabID] == task {
            reconnectTasks[tabID] = nil
        }
        return result
    }

    /// Renames a local-only terminal immediately. Persistent terminals first rename
    /// their remote workspace and commit the local title only after that succeeds.
    public func rename(
        _ tabID: String,
        to value: String
    ) async -> Result<TerminalTab, TerminalLaunchFailure> {
        guard let tab = store.tab(id: tabID) else {
            return .failure(TerminalLaunchFailure(message: L("终端会话不存在")))
        }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            store.updateAlias(tabID, to: "")
            guard let updated = store.tab(id: tabID) else {
                return .failure(TerminalLaunchFailure(message: L("终端会话不存在")))
            }
            return .success(updated)
        }

        guard case let .persistent(descriptor) = tab.reconnectDescriptor else {
            store.updateAlias(tabID, to: name)
            guard let updated = store.tab(id: tabID) else {
                return .failure(TerminalLaunchFailure(message: L("终端会话不存在")))
            }
            return .success(updated)
        }

        do {
            guard let host = try hostRepository.host(id: tab.hostID) else {
                throw TerminalLaunchFailure(message: L("主机已被删除"))
            }
            try await persistentBackend.renameWorkspace(
                descriptor,
                to: name,
                host: host,
                connectionManager: connectionManager
            )
            guard let current = store.tab(id: tabID),
                  current.reconnectDescriptor == .persistent(descriptor)
            else {
                return .failure(TerminalLaunchFailure(message: L("终端会话已关闭")))
            }
            store.updatePersistentWorkspaceName(tabID, to: name)
            guard let updated = store.tab(id: tabID) else {
                return .failure(TerminalLaunchFailure(message: L("终端会话已关闭")))
            }
            return .success(updated)
        } catch let failure as TerminalLaunchFailure {
            return .failure(failure)
        } catch {
            return .failure(TerminalLaunchFailure(message: terminalUserFacingDiagnosis(error)))
        }
    }

    /// App 长时间退到后台后，只恢复已经断开或底层连接明确死亡的终端。
    ///
    /// iOS 暂停 App 并不等于 TCP 已断；健康 PTY/tmux attachment 必须原样保留。
    /// 半开 socket 无法通过同步存活标志充分判定，继续由真实读写失败的生命周期路径处理，
    /// 这里不向用户终端注入探测字节。
    public func resumeAfterBackground(idleFor: TimeInterval) async {
        guard idleFor > 30 else { return }

        var candidates: [TerminalForegroundRecoveryCandidate] = []
        candidates.reserveCapacity(store.tabs.count)
        for tab in store.tabs {
            guard let host = try? hostRepository.host(id: tab.hostID) else { continue }
            let poolHealth = await connectionManager.pooledSessionHealth(for: host)
            candidates.append(TerminalForegroundRecoveryCandidate(
                id: tab.id,
                status: tab.status,
                poolHealth: poolHealth,
                lastUsedAt: tab.lastUsedAt
            ))
        }

        let tabIDs = TerminalForegroundRecoveryPolicy.orderedCandidateIDs(
            from: candidates,
            currentTabID: store.currentTabID
        )
        await recoverInBackground(tabIDs, maximumConcurrent: 2)
    }

    private func recoverInBackground(
        _ tabIDs: [String],
        maximumConcurrent: Int
    ) async {
        guard !tabIDs.isEmpty else { return }
        let limit = max(1, maximumConcurrent)
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < tabIDs.count else { return }
                let tabID = tabIDs[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.reconnect(tabID)
                }
            }

            for _ in 0 ..< min(limit, tabIDs.count) {
                enqueueNext()
            }
            while await group.next() != nil {
                enqueueNext()
            }
        }
    }

    public func close(_ tabID: String) async {
        lifecycleTasks.removeValue(forKey: tabID)?.cancel()
        attachmentLifecycleTasks.removeValue(forKey: tabID)?.cancel()
        automaticRecoveryTasks.removeValue(forKey: tabID)?.task.cancel()
        reconnectTasks.removeValue(forKey: tabID)?.cancel()
        await store.close(tabID)
    }

    public func closeAll(forHost hostID: String) async {
        await invalidatePendingLaunches(forHost: hostID)
        for tab in store.tabs(forHost: hostID) {
            lifecycleTasks.removeValue(forKey: tab.id)?.cancel()
            attachmentLifecycleTasks.removeValue(forKey: tab.id)?.cancel()
            automaticRecoveryTasks.removeValue(forKey: tab.id)?.task.cancel()
            reconnectTasks.removeValue(forKey: tab.id)?.cancel()
        }
        await store.closeAll(forHost: hostID)
    }

    /// 主机保存后的会话联动。
    ///
    /// 仅名称/备注/分组等展示信息变更时保留会话；地址、端口、用户名、认证材料或
    /// 跳板链变更时，旧 PTY 的实际目标已不再可信，必须关掉全部会话并驱逐旧连接。
    public func hostDidSave(
        _ host: ConnKit.Host,
        replacing previousHost: ConnKit.Host?,
        connectionIdentityChanged: Bool
    ) async {
        guard connectionIdentityChanged, let previousHost else {
            refreshHostName(host)
            return
        }

        await closeAll(forHost: host.id)
        await connectionManager.invalidate(host: previousHost)
    }

    /// 删除主机前先关闭其 PTY，并驱逐这台主机对应的共享 SSH 连接。
    public func hostDidDelete(_ host: ConnKit.Host) async {
        await closeAll(forHost: host.id)
        await connectionManager.invalidate(host: host)
    }

    public func refreshHostName(_ host: ConnKit.Host) {
        store.refreshHostName(hostID: host.id, name: host.name)
    }

    private func launchNew(
        _ request: TerminalLaunchRequest
    ) async -> Result<TerminalTab, TerminalLaunchFailure> {
        let attemptID = beginLaunchAttempt()
        switch await prepareLaunch(request, attemptID: attemptID) {
        case .success:
            return await commitLaunch(attemptID: attemptID)
        case let .failure(failure):
            return .failure(failure)
        }
    }

    private func prepareTab(
        for request: TerminalLaunchRequest,
        expectedHostLaunchGeneration: UInt64
    ) async -> Result<PreparedLaunch, TerminalLaunchFailure> {
        var temporarySession: TerminalSession?
        var temporaryAttachment: (any PersistentTerminalAttachment)?
        do {
            guard isLaunchCurrent(forHost: request.host.id, expectedGeneration: expectedHostLaunchGeneration),
                  let host = try hostRepository.host(id: request.host.id)
            else {
                return .failure(TerminalLaunchFailure(message: L("终端会话启动已取消")))
            }

            let opened = try await openBackend(request.backend, for: host, reason: .initial)
            let channel = opened.channel
            temporaryAttachment = opened.attachment
            let transcript = TerminalTranscript()
            let generation: UInt64 = 1
            await transcript.activateGeneration(generation)
            let session = TerminalSession(channel: channel, transcript: transcript, generation: generation)
            temporarySession = session

            // 打开 PTY 期间主机可能已删除或被编辑为另一条连接；不允许旧任务发送命令
            // 或写回会话中心，且须自行关闭这条无人持有的 PTY。
            guard isLaunchCurrent(forHost: request.host.id, expectedGeneration: expectedHostLaunchGeneration),
                  (try hostRepository.host(id: request.host.id)) != nil
            else {
                await session.close()
                await temporaryAttachment?.close()
                return .failure(TerminalLaunchFailure(message: L("终端会话启动已取消")))
            }

            if let initialCommand = request.initialCommand {
                try await session.send(Array("\(initialCommand)\n".utf8))
            }

            let reconnectDescriptor: TerminalReconnectDescriptor = switch request.backend {
            case .plainPTY:
                request.replayInitialCommandOnReconnect
                    ? TerminalReconnectDescriptor(commandToReplay: request.initialCommand)
                    : .shell
            case let .persistent(descriptor):
                .persistent(descriptor)
            }
            let tab = TerminalTab(
                hostID: host.id,
                hostName: host.name,
                hostAddress: host.displayAddress,
                session: session,
                persistentAttachment: opened.attachment,
                transcript: transcript,
                source: request.source,
                reconnectDescriptor: reconnectDescriptor,
                automaticAlias: automaticAlias(for: request, hostID: host.id),
                generation: generation
            )
            return .success(PreparedLaunch(tab: tab))
        } catch {
            if let temporarySession {
                await temporarySession.close()
            }
            await temporaryAttachment?.close()
            return .failure(TerminalLaunchFailure(message: terminalUserFacingDiagnosis(error)))
        }
    }

    private func closePreparedLaunch(_ prepared: PreparedLaunch) async {
        await prepared.tab.session.close()
        await prepared.tab.persistentAttachment?.close()
    }

    private func replaceDisconnectedTab(_ tabID: String) async -> Result<TerminalTab, TerminalLaunchFailure> {
        guard let oldTab = store.tab(id: tabID) else {
            return .failure(TerminalLaunchFailure(message: L("终端会话不存在")))
        }
        let nextGeneration = oldTab.generation + 1
        store.updateStatus(tabID, to: .reconnecting)
        // 先失效旧代次，再关闭旧 PTY；任何迟到输出都不会污染新 generation。
        await oldTab.transcript.activateGeneration(nextGeneration)
        await oldTab.transcript.resetForGeneration(nextGeneration)
        lifecycleTasks.removeValue(forKey: tabID)?.cancel()
        attachmentLifecycleTasks.removeValue(forKey: tabID)?.cancel()
        await oldTab.session.close()
        await oldTab.persistentAttachment?.close()

        var temporarySession: TerminalSession?
        do {
            guard let host = try hostRepository.host(id: oldTab.hostID) else {
                throw TerminalLaunchFailure(message: L("主机已被删除"))
            }
            let backend: TerminalLaunchBackend = switch oldTab.reconnectDescriptor {
            case .shell, .replayCommand:
                .plainPTY
            case let .persistent(descriptor):
                .persistent(descriptor)
            }
            let opened = try await openBackend(backend, for: host, reason: .reconnect)
            let channel = opened.channel
            let session = TerminalSession(
                channel: channel,
                transcript: oldTab.transcript,
                generation: nextGeneration
            )
            temporarySession = session

            if let command = oldTab.reconnectDescriptor.commandToReplay {
                try await session.send(Array("\(command)\n".utf8))
            }
            guard let current = store.tab(id: tabID), current.generation == oldTab.generation else {
                await session.close()
                await opened.attachment?.close()
                return .failure(TerminalLaunchFailure(message: L("终端会话已关闭")))
            }

            await oldTab.transcript.appendGenerationBoundary(nextGeneration)
            store.replaceSession(
                tabID,
                session: session,
                generation: nextGeneration,
                persistentAttachment: opened.attachment
            )
            await session.start()
            observeLifecycle(for: tabID, generation: nextGeneration, session: session)
            observeAttachmentLifecycle(
                for: tabID,
                generation: nextGeneration,
                attachment: opened.attachment
            )
            guard let replacement = store.tab(id: tabID) else {
                return .failure(TerminalLaunchFailure(message: L("终端会话已关闭")))
            }
            return .success(replacement)
        } catch {
            if let temporarySession {
                await temporarySession.close()
            }
            let message = terminalUserFacingDiagnosis(error)
            if store.tab(id: tabID)?.generation == oldTab.generation {
                store.updateStatus(tabID, to: .disconnected(message: message))
            }
            return .failure(TerminalLaunchFailure(message: message))
        }
    }

    private struct OpenedBackend: Sendable {
        let channel: any ShellChannel
        let attachment: (any PersistentTerminalAttachment)?
    }

    private func openBackend(
        _ backend: TerminalLaunchBackend,
        for host: ConnKit.Host,
        reason: PersistentAttachmentOpenReason
    ) async throws -> OpenedBackend {
        switch backend {
        case .plainPTY:
            return OpenedBackend(
                channel: try await openShell(for: host),
                attachment: nil
            )

        case let .persistent(descriptor):
            let opened = try await persistentBackend.open(
                descriptor,
                for: host,
                connectionManager: connectionManager,
                reason: reason,
                terminalSize: TermSize(cols: 80, rows: 24)
            )
            return OpenedBackend(channel: opened.channel, attachment: opened.attachment)
        }
    }

    /// Plain PTY and persistent providers use the same staged-startup contract. A plain
    /// terminal composes only transport + byte terminal + readiness; tmux adds its own
    /// required Control Mode and identity-binding stages inside the provider.
    ///
    /// PTY 打开失败通常意味着共享 SSH 已半开。仅在 byte-terminal 阶段驱逐一次并
    /// 重新握手，避免无限重试。断线恢复会重新调用本方法，因此不维护第二套恢复流程。
    private func openShell(for host: ConnKit.Host) async throws -> any ShellChannel {
        let startup = PlainPTYStartupTransaction()
        let manager = connectionManager
        let terminalSize = TermSize(cols: 80, rows: 24)
        let pipeline = TerminalStartupPipeline(steps: [
            .init(id: .remoteTransport) {
                let session = try await manager.session(for: host)
                await startup.storeSession(session)
                return nil
            },
            .init(id: .byteTerminal) {
                let firstSession = try await startup.session()
                let channel: any ShellChannel
                do {
                    channel = try await firstSession.openShell(term: terminalSize)
                } catch {
                    await manager.invalidate(host: host)
                    let refreshedSession = try await manager.session(for: host)
                    await startup.storeSession(refreshedSession)
                    channel = try await refreshedSession.openShell(term: terminalSize)
                }
                await startup.storeChannel(channel)
                return TerminalStartupRollback {
                    await startup.rollbackChannel()
                }
            },
            .init(id: .readiness) {
                _ = try await startup.finishedChannel()
                return nil
            },
        ])
        try await pipeline.run()
        return try await startup.finishedChannel()
    }

    private func observeLifecycle(for tabID: String, generation: UInt64, session: TerminalSession) {
        lifecycleTasks.removeValue(forKey: tabID)?.cancel()
        lifecycleTasks[tabID] = Task { [weak self] in
            for await event in session.lifecycleEvents {
                guard !Task.isCancelled else { return }
                self?.receive(event, tabID: tabID, generation: generation)
            }
        }
    }

    private func observeAttachmentLifecycle(
        for tabID: String,
        generation: UInt64,
        attachment: (any PersistentTerminalAttachment)?
    ) {
        attachmentLifecycleTasks.removeValue(forKey: tabID)?.cancel()
        guard let attachment else { return }
        attachmentLifecycleTasks[tabID] = Task { [weak self] in
            for await event in attachment.lifecycleEvents {
                guard !Task.isCancelled else { return }
                self?.receive(event, tabID: tabID, generation: generation)
            }
        }
    }

    private func receive(
        _ event: PersistentTerminalAttachmentLifecycleEvent,
        tabID: String,
        generation: UInt64
    ) {
        guard let tab = store.tab(id: tabID), tab.generation == generation else { return }
        switch event {
        case let .failed(failure):
            store.updateStatus(
                tabID,
                to: .disconnected(message: failure.issue.userFacingDiagnosis)
            )
            if failure.recovery == .rebuildAttachment {
                scheduleAutomaticRecovery(tabID: tabID, generation: generation)
            }
        }
    }

    /// A required auxiliary component (for example tmux Control Mode) invalidates the
    /// complete attachment generation. Rebuild uses the exact same descriptor and startup
    /// pipeline as initial launch, with a small bounded retry sequence for transient loss.
    private func scheduleAutomaticRecovery(tabID: String, generation: UInt64) {
        // Mark the tab as rebuilding before the first bounded backoff. The UI must expose
        // the recovery state during that wait; otherwise a foreground resume or a required
        // Control Mode rebuild looks indistinguishable from a silently disconnected tab.
        guard let tab = store.tab(id: tabID), tab.generation == generation else { return }
        store.updateStatus(tabID, to: .reconnecting)
        if let existing = automaticRecoveryTasks[tabID] {
            guard existing.generation != generation else { return }
            existing.task.cancel()
        }
        let recoveryID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.automaticRecoveryTasks[tabID]?.id == recoveryID {
                    self.automaticRecoveryTasks[tabID] = nil
                }
            }
            let delays: [Duration] = [.milliseconds(200), .seconds(1), .seconds(3)]
            for delay in delays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let current = self.store.tab(id: tabID),
                      current.generation == generation
                else { return }
                if case .success = await self.reconnect(tabID) {
                    return
                }
            }
        }
        automaticRecoveryTasks[tabID] = AutomaticRecoveryTask(
            id: recoveryID,
            generation: generation,
            task: task
        )
    }

    private func receive(_ event: TerminalSessionLifecycleEvent, tabID: String, generation: UInt64) {
        guard let tab = store.tab(id: tabID), tab.generation == generation else { return }
        switch event {
        case .closed:
            store.updateStatus(tabID, to: .disconnected(message: nil))
        case let .failed(message):
            store.updateStatus(tabID, to: .disconnected(message: message))
        }
    }

    private func launchGeneration(forHost hostID: String) -> UInt64 {
        hostLaunchGenerations[hostID, default: 0]
    }

    private func invalidatePendingLaunches(forHost hostID: String) async {
        hostLaunchGenerations[hostID] = launchGeneration(forHost: hostID) &+ 1
        inFlightLaunches.removeValue(forKey: hostID)?.cancel()
        let attemptIDs = launchAttempts.compactMap { attemptID, state in
            switch state {
            case let .preparing(attemptHostID, _):
                attemptHostID == hostID ? attemptID : nil
            case let .prepared(prepared):
                prepared.tab.hostID == hostID ? attemptID : nil
            case .pending, .cancelled:
                nil
            }
        }
        for attemptID in attemptIDs {
            await cancelLaunch(attemptID: attemptID)
        }
    }

    private func isLaunchCurrent(forHost hostID: String, expectedGeneration: UInt64) -> Bool {
        launchGeneration(forHost: hostID) == expectedGeneration
    }

    private func automaticAlias(for request: TerminalLaunchRequest, hostID: String) -> String {
        if let automaticAlias = request.automaticAlias { return automaticAlias }
        switch request.source {
        case .shell:
            let names = Set(store.tabs(forHost: hostID).map(\.automaticAlias))
            var index = 1
            let prefix = L("终端")
            while names.contains("\(prefix) \(index)") {
                index += 1
            }
            return "\(prefix) \(index)"
        case let .docker(containerName):
            return containerName
        case let .script(title):
            return title
        case let .persistent(providerID):
            return providerID
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private enum PlainPTYStartupTransactionError: Error, Sendable {
    case missingSession
    case missingChannel
}

private actor PlainPTYStartupTransaction {
    private var openedSession: (any SSHSession)?
    private var openedChannel: (any ShellChannel)?

    func storeSession(_ session: any SSHSession) {
        openedSession = session
    }

    func session() throws -> any SSHSession {
        guard let openedSession else {
            throw PlainPTYStartupTransactionError.missingSession
        }
        return openedSession
    }

    func storeChannel(_ channel: any ShellChannel) {
        openedChannel = channel
    }

    func rollbackChannel() async {
        guard let openedChannel else { return }
        self.openedChannel = nil
        await openedChannel.close()
    }

    func finishedChannel() throws -> any ShellChannel {
        guard let openedChannel else {
            throw PlainPTYStartupTransactionError.missingChannel
        }
        return openedChannel
    }
}
