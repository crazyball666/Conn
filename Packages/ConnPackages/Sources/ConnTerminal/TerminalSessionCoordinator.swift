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
    public let initialCommand: String?
    public let replayInitialCommandOnReconnect: Bool

    public init(
        host: ConnKit.Host,
        policy: TerminalLaunchPolicy,
        source: TerminalSessionSource,
        backend: TerminalLaunchBackend = .plainPTY,
        initialCommand: String? = nil,
        replayInitialCommandOnReconnect: Bool = false
    ) {
        self.host = host
        self.policy = policy
        self.source = source
        self.backend = backend
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
    private let persistentBackend: PersistentProviderBackend?
    private let profileProvisioner: ((ConnKit.Host) -> Void)?
    private var inFlightLaunches: [String: Task<Result<TerminalTab, TerminalLaunchFailure>, Never>] = [:]
    /// 主机删除/连接身份变更时递增。Citadel 的建连与开 PTY 不一定响应 cancellation，
    /// 所以必须在完成后再用这个代次阻止旧任务把会话写回 store。
    private var hostLaunchGenerations: [String: UInt64] = [:]
    private var reconnectTasks: [String: Task<Result<TerminalTab, TerminalLaunchFailure>, Never>] = [:]
    private var lifecycleTasks: [String: Task<Void, Never>] = [:]
    private var consumedFailureIDs: Set<UUID> = []

    public init(
        hostRepository: any HostRepository,
        connectionManager: ConnectionManager,
        providerRegistry: PersistentTerminalProviderRegistry = .default,
        profileRepository: (any TerminalBackendProfileRepository)? = nil,
        profileProvisioner: ((ConnKit.Host) -> Void)? = nil
    ) {
        self.hostRepository = hostRepository
        self.connectionManager = connectionManager
        self.profileProvisioner = profileProvisioner
        if let profileRepository {
            self.persistentBackend = PersistentProviderBackend(
                registry: providerRegistry,
                profileRepository: profileRepository
            )
        } else {
            self.persistentBackend = nil
        }
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
            let generation = launchGeneration(forHost: key)
            let task: Task<Result<TerminalTab, TerminalLaunchFailure>, Never> = Task { [weak self] in
                guard let self else {
                    return Result.failure(TerminalLaunchFailure(message: L("终端协调器已释放")))
                }
                return await self.createTab(for: request, expectedHostLaunchGeneration: generation)
            }
            inFlightLaunches[key] = task
            let result = await task.value
            if inFlightLaunches[key] == task {
                inFlightLaunches[key] = nil
            }
            return result

        case .createNew:
            return await createTab(
                for: request,
                expectedHostLaunchGeneration: launchGeneration(forHost: request.host.id)
            )
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
    public func persistentBackendCandidates(
        for host: ConnKit.Host
    ) async -> [PersistentBackendCandidate] {
        guard let persistentBackend else { return [] }
        return await persistentBackend.candidates(
            for: host,
            connectionManager: connectionManager
        )
    }

    public func makePersistentBackend(
        from candidate: PersistentBackendCandidate,
        for host: ConnKit.Host
    ) async throws -> TerminalLaunchBackend {
        guard let persistentBackend else {
            throw PersistentTerminalError.profileUnavailable(candidate.profileID)
        }
        let descriptor = try await persistentBackend.defaultDescriptor(
            for: candidate,
            host: host,
            connectionManager: connectionManager
        )
        return .persistent(descriptor)
    }

    public func persistentWorkspaceOptions(
        for candidate: PersistentBackendCandidate,
        host: ConnKit.Host
    ) async throws -> [RemoteWorkspaceSummary] {
        guard let persistentBackend else {
            throw PersistentTerminalError.profileUnavailable(candidate.profileID)
        }
        return try await persistentBackend.workspaceOptions(
            for: candidate,
            host: host,
            connectionManager: connectionManager
        )
    }

    public func makePersistentBackend(
        from candidate: PersistentBackendCandidate,
        workspace: RemoteWorkspaceRef,
        for host: ConnKit.Host
    ) async throws -> TerminalLaunchBackend {
        guard let persistentBackend else {
            throw PersistentTerminalError.profileUnavailable(candidate.profileID)
        }
        let descriptor = try await persistentBackend.descriptor(
            for: workspace,
            providerID: candidate.providerID,
            profileID: candidate.profileID,
            host: host,
            connectionManager: connectionManager
        )
        return .persistent(descriptor)
    }

    public func makePersistentBackend(
        from candidate: PersistentBackendCandidate,
        create selection: PersistentWorkspaceCreateSelection,
        for host: ConnKit.Host
    ) async throws -> TerminalLaunchBackend {
        guard let persistentBackend else {
            throw PersistentTerminalError.profileUnavailable(candidate.profileID)
        }
        let descriptor = try await persistentBackend.createDescriptor(
            for: selection,
            candidate: candidate,
            host: host,
            connectionManager: connectionManager
        )
        return .persistent(descriptor)
    }

    public func openPersistentCatalog(
        for candidate: PersistentBackendCandidate,
        host: ConnKit.Host
    ) async throws -> any PersistentTerminalCatalogAttachment {
        guard let persistentBackend else {
            throw PersistentTerminalError.profileUnavailable(candidate.profileID)
        }
        return try await persistentBackend.openCatalog(
            for: candidate,
            host: host,
            connectionManager: connectionManager
        )
    }

    public func makePersistentAttachmentDescriptor(
        for workspace: RemoteWorkspaceRef,
        providerID: String,
        profileID: String,
        host: ConnKit.Host
    ) async throws -> PersistentAttachmentDescriptor {
        guard let persistentBackend else {
            throw PersistentTerminalError.profileUnavailable(profileID)
        }
        return try await persistentBackend.descriptor(
            for: workspace,
            providerID: providerID,
            profileID: profileID,
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

    /// App 长时间退到后台后，SSH 连接可能已被系统回收；回前台时重建所有 PTY。
    /// 即使旧 tab 仍显示 connected 也要重建，因为半开 socket 不一定会先发布 EOF。
    public func resumeAfterBackground(idleFor: TimeInterval) async {
        guard idleFor > 30 else { return }
        let tabIDs = store.tabs.map(\.id)
        for tabID in tabIDs {
            _ = await reconnect(tabID)
        }
    }

    public func close(_ tabID: String) async {
        lifecycleTasks.removeValue(forKey: tabID)?.cancel()
        reconnectTasks.removeValue(forKey: tabID)?.cancel()
        await store.close(tabID)
    }

    public func closeAll(forHost hostID: String) async {
        invalidatePendingLaunches(forHost: hostID)
        for tab in store.tabs(forHost: hostID) {
            lifecycleTasks.removeValue(forKey: tab.id)?.cancel()
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
        profileProvisioner?(host)
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

    private func createTab(
        for request: TerminalLaunchRequest,
        expectedHostLaunchGeneration: UInt64
    ) async -> Result<TerminalTab, TerminalLaunchFailure> {
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
                automaticAlias: automaticAlias(for: request.source, hostID: host.id),
                generation: generation
            )
            store.add(tab)
            await session.start()
            observeLifecycle(for: tab.id, generation: generation, session: session)
            return .success(tab)
        } catch {
            if let temporarySession {
                await temporarySession.close()
            }
            await temporaryAttachment?.close()
            return .failure(TerminalLaunchFailure(message: error.friendlyDiagnosis))
        }
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
            guard let replacement = store.tab(id: tabID) else {
                return .failure(TerminalLaunchFailure(message: L("终端会话已关闭")))
            }
            return .success(replacement)
        } catch {
            if let temporarySession {
                await temporarySession.close()
            }
            if store.tab(id: tabID)?.generation == oldTab.generation {
                store.updateStatus(tabID, to: .disconnected(message: error.friendlyDiagnosis))
            }
            return .failure(TerminalLaunchFailure(message: error.friendlyDiagnosis))
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
            guard let persistentBackend else {
                throw PersistentTerminalError.profileUnavailable(descriptor.profileID)
            }
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

    /// PTY 打开失败通常意味着共享 SSH 已半开。仅在这一步驱逐一次并重新握手，避免无限重试。
    private func openShell(for host: ConnKit.Host) async throws -> any ShellChannel {
        var retriedAfterOpenFailure = false
        while true {
            let sshSession = try await connectionManager.session(for: host)
            do {
                return try await sshSession.openShell(term: TermSize(cols: 80, rows: 24))
            } catch {
                guard !retriedAfterOpenFailure else { throw error }
                retriedAfterOpenFailure = true
                await connectionManager.invalidate(host: host)
            }
        }
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

    private func invalidatePendingLaunches(forHost hostID: String) {
        hostLaunchGenerations[hostID] = launchGeneration(forHost: hostID) &+ 1
        inFlightLaunches.removeValue(forKey: hostID)?.cancel()
    }

    private func isLaunchCurrent(forHost hostID: String, expectedGeneration: UInt64) -> Bool {
        launchGeneration(forHost: hostID) == expectedGeneration
    }

    private func automaticAlias(for source: TerminalSessionSource, hostID: String) -> String {
        switch source {
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
