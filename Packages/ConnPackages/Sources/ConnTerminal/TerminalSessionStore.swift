import ConnMultiplexer
import ConnUI
import Foundation
import Observation

/// 会话由哪个功能入口创建。只用于活动 Tab 的展示和重连规则；恢复书签只保存
/// provider descriptor，不持久化这个 UI 来源枚举。
public enum TerminalSessionSource: Sendable, Equatable {
    case shell
    case docker(containerName: String)
    case script(title: String)
    case persistent(providerID: String)
}

public enum TerminalTabStatus: Sendable, Equatable {
    case connected
    case disconnected(message: String?)
    case reconnecting
}

/// 重连信息与展示来源分离：持久化 backend 必须消费原始 descriptor，不能从
/// source、别名或初始命令反推远端对象。
public enum TerminalReconnectDescriptor: Sendable, Equatable {
    case shell
    case replayCommand(String)
    case persistent(PersistentAttachmentDescriptor)

    public init(commandToReplay: String? = nil) {
        if let commandToReplay {
            self = .replayCommand(commandToReplay)
        } else {
            self = .shell
        }
    }

    public var commandToReplay: String? {
        if case let .replayCommand(command) = self { return command }
        return nil
    }
}

/// 会话中心按主机渲染时使用的稳定分组。
public struct TerminalHostSessionGroup: Identifiable, Sendable {
    public let hostID: String
    public let hostName: String
    public let hostAddress: String
    public let tabs: [TerminalTab]
    public let resumeRecords: [PersistentTerminalResumeRecord]

    public var id: String { hostID }
    public var terminalCount: Int { tabs.count + resumeRecords.count }

    public init(
        hostID: String,
        hostName: String,
        hostAddress: String,
        tabs: [TerminalTab],
        resumeRecords: [PersistentTerminalResumeRecord] = []
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostAddress = hostAddress
        self.tabs = tabs
        self.resumeRecords = resumeRecords
    }
}

/// 一个活跃终端会话的句柄。完整 Tab 与 PTY 只在内存保存；持久 provider 只会
/// 从中投影出最小恢复书签，不保存 transcript、channel 或瞬时状态。
public struct TerminalTab: Identifiable, Sendable {
    public let id: String
    public let hostID: String
    public var hostName: String
    public var hostAddress: String
    public var session: TerminalSession
    /// Kept alongside the byte channel so provider-owned leases are released after
    /// the local TerminalSession stops. Never extract only `presentation` and drop it.
    public var persistentAttachment: (any PersistentTerminalAttachment)?
    public let transcript: TerminalTranscript
    public let source: TerminalSessionSource
    public var reconnectDescriptor: TerminalReconnectDescriptor
    public var automaticAlias: String
    public var alias: String?
    public var status: TerminalTabStatus
    public var generation: UInt64
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: String = UUID().uuidString,
        hostID: String,
        hostName: String,
        hostAddress: String = "",
        session: TerminalSession,
        persistentAttachment: (any PersistentTerminalAttachment)? = nil,
        transcript: TerminalTranscript = TerminalTranscript(),
        source: TerminalSessionSource = .shell,
        reconnectDescriptor: TerminalReconnectDescriptor = .init(),
        automaticAlias: String = L("终端"),
        alias: String? = nil,
        status: TerminalTabStatus = .connected,
        generation: UInt64 = 0,
        createdAt: Date = .now,
        lastUsedAt: Date = .now
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.hostAddress = hostAddress
        self.session = session
        self.persistentAttachment = persistentAttachment
        self.transcript = transcript
        self.source = source
        self.reconnectDescriptor = reconnectDescriptor
        self.automaticAlias = automaticAlias
        self.alias = Self.cleanedAlias(alias)
        self.status = status
        self.generation = generation
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public var displayName: String { alias ?? automaticAlias }

    private static func cleanedAlias(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 多会话管理。页面切换不会关闭 session；显式 close 才关闭对应 PTY。
@Observable
@MainActor
public final class TerminalSessionStore {
    public private(set) var tabs: [TerminalTab] = []
    public private(set) var resumeRecords: [PersistentTerminalResumeRecord]
    public private(set) var currentTabID: String?

    public init(resumeRecords: [PersistentTerminalResumeRecord] = []) {
        self.resumeRecords = []
        for record in resumeRecords.sorted(by: { $0.lastConnectedAt < $1.lastConnectedAt }) {
            upsertResumeRecord(record)
        }
    }

    public var currentTab: TerminalTab? {
        tabs.first { $0.id == currentTabID }
    }

    public var hostGroups: [TerminalHostSessionGroup] {
        var groups: [TerminalHostSessionGroup] = []
        var indices: [String: Int] = [:]
        for tab in tabs {
            if let index = indices[tab.hostID] {
                groups[index] = TerminalHostSessionGroup(
                    hostID: groups[index].hostID,
                    hostName: groups[index].hostName,
                    hostAddress: groups[index].hostAddress,
                    tabs: groups[index].tabs + [tab],
                    resumeRecords: groups[index].resumeRecords
                )
            } else {
                indices[tab.hostID] = groups.count
                groups.append(TerminalHostSessionGroup(
                    hostID: tab.hostID,
                    hostName: tab.hostName,
                    hostAddress: tab.hostAddress,
                    tabs: [tab]
                ))
            }
        }

        let activeIdentities = Set(tabs.compactMap(\.persistentResumeIdentity))
        for record in resumeRecords where !activeIdentities.contains(record.identity) {
            if let index = indices[record.hostID] {
                groups[index] = TerminalHostSessionGroup(
                    hostID: groups[index].hostID,
                    hostName: groups[index].hostName,
                    hostAddress: groups[index].hostAddress,
                    tabs: groups[index].tabs,
                    resumeRecords: groups[index].resumeRecords + [record]
                )
            } else {
                indices[record.hostID] = groups.count
                groups.append(TerminalHostSessionGroup(
                    hostID: record.hostID,
                    hostName: record.hostName,
                    hostAddress: record.hostAddress,
                    tabs: [],
                    resumeRecords: [record]
                ))
            }
        }
        return groups
    }

    public func resumeRecord(id: String) -> PersistentTerminalResumeRecord? {
        resumeRecords.first { $0.id == id }
    }

    public func upsertResumeRecord(_ record: PersistentTerminalResumeRecord) {
        resumeRecords.removeAll { $0.id == record.id || $0.identity == record.identity }
        resumeRecords.append(record)
        resumeRecords.sort { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    @discardableResult
    public func removeResumeRecord(id: String) -> PersistentTerminalResumeRecord? {
        guard let index = resumeRecords.firstIndex(where: { $0.id == id }) else { return nil }
        return resumeRecords.remove(at: index)
    }

    public func removeResumeRecords(forHost hostID: String) {
        resumeRecords.removeAll { $0.hostID == hostID }
    }

    public func tab(id: String) -> TerminalTab? {
        tabs.first { $0.id == id }
    }

    public func tabs(forHost hostID: String) -> [TerminalTab] {
        tabs.filter { $0.hostID == hostID }
    }

    public func recentTab(forHost hostID: String) -> TerminalTab? {
        tabs(forHost: hostID).max { $0.lastUsedAt < $1.lastUsedAt }
    }

    /// 兼容旧调用点：当前语义等同于最近使用会话。
    public func existingTab(forHost hostID: String) -> TerminalTab? {
        recentTab(forHost: hostID)
    }

    public func add(_ tab: TerminalTab) {
        tabs.append(tab)
        select(tab.id)
    }

    public func select(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        currentTabID = tabID
        tabs[index].lastUsedAt = .now
    }

    public func updateAlias(_ tabID: String, to value: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].alias = trimmed.isEmpty ? nil : trimmed
    }

    /// Commits provider-owned workspace metadata after a successful remote rename.
    /// The workspace name becomes the new automatic title; a stale local override
    /// must not hide it.
    public func updatePersistentWorkspaceName(_ tabID: String, to value: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabs[index].automaticAlias = trimmed
        tabs[index].alias = nil
    }

    /// Rebinds a live persistent terminal after its provider reports that the owned client
    /// moved to another workspace. Opaque provider data remains untouched.
    @discardableResult
    public func updatePersistentWorkspaceBinding(
        _ tabID: String,
        workspaceID: String,
        workspaceName: String?
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              case let .persistent(descriptor) = tabs[index].reconnectDescriptor,
              !workspaceID.isEmpty,
              descriptor.workspace.workspaceID != workspaceID
        else { return false }

        let workspace = RemoteWorkspaceRef(
            workspaceID: workspaceID,
            instancePayloadVersion: descriptor.workspace.instancePayloadVersion,
            providerInstancePayload: descriptor.workspace.providerInstancePayload
        )
        tabs[index].reconnectDescriptor = .persistent(PersistentAttachmentDescriptor(
            providerID: descriptor.providerID,
            configuration: descriptor.configuration,
            workspace: workspace,
            payloadVersion: descriptor.payloadVersion,
            providerPayload: descriptor.providerPayload
        ))
        if let workspaceName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspaceName.isEmpty {
            tabs[index].automaticAlias = workspaceName
        }
        // A local override labels the previous workspace and must not leak to the new one.
        tabs[index].alias = nil
        tabs[index].lastUsedAt = .now
        return true
    }

    public func updateStatus(_ tabID: String, to status: TerminalTabStatus) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].status = status
    }

    public func replaceSession(
        _ tabID: String,
        session: TerminalSession,
        generation: UInt64,
        status: TerminalTabStatus = .connected,
        persistentAttachment: (any PersistentTerminalAttachment)? = nil
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].session = session
        tabs[index].generation = generation
        tabs[index].status = status
        tabs[index].persistentAttachment = persistentAttachment
        tabs[index].lastUsedAt = .now
    }

    /// 更新会话中心中主机的展示名称。
    ///
    /// 连接地址属于会话建立时的连接身份，不应在编辑主机元数据时重新拼接或覆盖。
    /// 这样可以避免保存主机时触发无意义的地址格式化，也保证已建立会话继续显示
    /// 当时使用的连接端点。
    public func refreshHostName(hostID: String, name: String) {
        // 不要在 `for … where` 的筛选表达式借用数组元素时，又通过同一个
        // subscript 修改元素。Release 优化下该模式曾让 String 的借用越过
        // 数组写入边界，最终在 `_StringObject.getSharedUTF8Start` 崩溃。
        // 先基于旧快照生成新值，再一次性提交给 Observation。
        tabs = tabs.map { tab in
            guard tab.hostID == hostID else { return tab }
            var updated = tab
            updated.hostName = name
            return updated
        }
        resumeRecords = resumeRecords.map { record in
            guard record.hostID == hostID else { return record }
            var updated = record
            updated.hostName = name
            return updated
        }
    }

    public func close(_ tabID: String) async {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs.remove(at: index)
        if currentTabID == tabID {
            currentTabID = tabs.last(where: { $0.hostID == tab.hostID })?.id ?? tabs.last?.id
        }
        await tab.session.close()
        await tab.persistentAttachment?.close()
    }

    public func closeAll(forHost hostID: String) async {
        let closing = tabs.filter { $0.hostID == hostID }
        tabs.removeAll { $0.hostID == hostID }
        if currentTabID.flatMap({ id in closing.contains { $0.id == id } }) != nil {
            currentTabID = tabs.last?.id
        }
        for tab in closing {
            await tab.session.close()
            await tab.persistentAttachment?.close()
        }
    }

    public func closeAll() async {
        let closing = tabs
        tabs.removeAll()
        currentTabID = nil
        for tab in closing {
            await tab.session.close()
            await tab.persistentAttachment?.close()
        }
    }
}

private extension TerminalTab {
    var persistentResumeIdentity: PersistentTerminalResumeIdentity? {
        guard case let .persistent(descriptor) = reconnectDescriptor else { return nil }
        return PersistentTerminalResumeIdentity(
            hostID: hostID,
            providerID: descriptor.providerID,
            configurationKey: descriptor.configurationKey,
            workspaceID: descriptor.workspace.workspaceID
        )
    }
}
