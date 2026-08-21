import ConnMultiplexer
import ConnSSH
import Foundation
import Testing
@testable import ConnTerminal

/// 用一个不产出的假通道构造 TerminalSession，仅测 store 的编排。
private func makeTab(hostID: String, name: String) -> TerminalTab {
    let channel = InertShellChannel()
    let session = TerminalSession(channel: channel)
    return TerminalTab(hostID: hostID, hostName: name, session: session)
}

private func makeResumeRecord(
    id: String = UUID().uuidString,
    hostID: String = "h1",
    workspaceID: String = "$1",
    name: String = "ops"
) -> PersistentTerminalResumeRecord {
    PersistentTerminalResumeRecord(
        id: id,
        hostID: hostID,
        hostName: hostID == "h1" ? "web" : "db",
        hostAddress: "root@\(hostID)",
        descriptor: PersistentAttachmentDescriptor(
            providerID: "tmux",
            configuration: PersistentTerminalConfiguration(
                providerID: "tmux",
                configurationKey: "default",
                payloadVersion: 1,
                providerPayload: Data()
            ),
            workspace: RemoteWorkspaceRef(
                workspaceID: workspaceID,
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        ),
        automaticAlias: name
    )
}

/// 永不产出、写入即丢弃的通道。
private final class InertShellChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init() { (output, continuation) = AsyncThrowingStream.makeStream() }
    func write(_ bytes: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func close() async { continuation.finish() }
}

@Suite("TerminalSessionStore — 多会话编排")
@MainActor
struct TerminalSessionStoreTests {
    @Test("加入会话后成为当前")
    func addBecomesCurrent() {
        let store = TerminalSessionStore()
        let tab = makeTab(hostID: "h1", name: "web-01")
        store.add(tab)
        #expect(store.tabs.count == 1)
        #expect(store.currentTabID == tab.id)
        #expect(store.currentTab?.id == tab.id)
    }

    @Test("关闭当前会话后切到相邻会话")
    func closeCurrentSwitchesToNeighbor() async {
        let store = TerminalSessionStore()
        let first = makeTab(hostID: "h1", name: "a")
        let second = makeTab(hostID: "h2", name: "b")
        store.add(first)
        store.add(second) // current = second
        await store.close(second.id)
        #expect(store.tabs.count == 1)
        #expect(store.currentTabID == first.id)
    }

    @Test("关闭非当前会话不改变当前")
    func closeOtherKeepsCurrent() async {
        let store = TerminalSessionStore()
        let first = makeTab(hostID: "h1", name: "a")
        let second = makeTab(hostID: "h2", name: "b")
        store.add(first)
        store.add(second)
        await store.close(first.id)
        #expect(store.currentTabID == second.id)
    }

    @Test("existingTab 找到同主机会话，避免重复开")
    func findsExistingTab() {
        let store = TerminalSessionStore()
        let tab = makeTab(hostID: "h1", name: "a")
        store.add(tab)
        #expect(store.existingTab(forHost: "h1")?.id == tab.id)
        #expect(store.existingTab(forHost: "h2") == nil)
    }

    @Test("closeAll 清空全部")
    func closeAllEmpties() async {
        let store = TerminalSessionStore()
        store.add(makeTab(hostID: "h1", name: "a"))
        store.add(makeTab(hostID: "h2", name: "b"))
        await store.closeAll()
        #expect(store.tabs.isEmpty)
        #expect(store.currentTabID == nil)
    }

    @Test("同一主机允许多个会话，并按最近选择复用")
    func supportsMultipleTabsPerHostAndTracksRecent() {
        let store = TerminalSessionStore()
        let first = makeTab(hostID: "h1", name: "web")
        let second = makeTab(hostID: "h1", name: "web")
        store.add(first)
        store.add(second)
        store.select(first.id)

        #expect(store.tabs(forHost: "h1").map(\.id) == [first.id, second.id])
        #expect(store.recentTab(forHost: "h1")?.id == first.id)
    }

    @Test("别名去空白，空别名恢复自动名称")
    func updatesAliasOrRestoresAutomaticName() {
        let store = TerminalSessionStore()
        let tab = makeTab(hostID: "h1", name: "web")
        store.add(tab)

        store.updateAlias(tab.id, to: "  部署窗口  ")
        #expect(store.tabs.first?.displayName == "部署窗口")
        store.updateAlias(tab.id, to: "   ")
        #expect(store.tabs.first?.displayName == "终端")
    }

    @Test("远端 Workspace 重命名后替换自动名称并清除本地覆盖")
    func updatesPersistentWorkspaceName() {
        let store = TerminalSessionStore()
        let channel = InertShellChannel()
        let tab = TerminalTab(
            hostID: "h1",
            hostName: "web",
            session: TerminalSession(channel: channel),
            automaticAlias: "ops",
            alias: "临时名称"
        )
        store.add(tab)

        store.updatePersistentWorkspaceName(tab.id, to: "production")

        #expect(store.tabs.first?.automaticAlias == "production")
        #expect(store.tabs.first?.alias == nil)
        #expect(store.tabs.first?.displayName == "production")
    }

    @Test("按主机分组只保留有会话的主机")
    func groupsTabsByHost() {
        let store = TerminalSessionStore()
        store.add(makeTab(hostID: "h1", name: "web"))
        store.add(makeTab(hostID: "h2", name: "db"))

        #expect(store.hostGroups.map(\.hostID) == ["h1", "h2"])
        #expect(store.hostGroups.map(\.hostName) == ["web", "db"])
        #expect(store.hostGroups.map { $0.tabs.count } == [1, 1])
    }

    @Test("仅有恢复记录的主机也进入终端列表分组")
    func groupsRestorableRecordsWithoutLiveTabs() {
        let record = makeResumeRecord(hostID: "h1", name: "production")
        let store = TerminalSessionStore(resumeRecords: [record])

        #expect(store.hostGroups.map(\.hostID) == ["h1"])
        #expect(store.hostGroups.first?.tabs.isEmpty == true)
        #expect(store.hostGroups.first?.resumeRecords == [record])
        #expect(store.hostGroups.first?.terminalCount == 1)
    }

    @Test("活动 Tab 覆盖同一恢复记录避免列表重复")
    func activeTabHidesItsResumeRecord() {
        let record = makeResumeRecord(id: "resume-1", hostID: "h1")
        let store = TerminalSessionStore(resumeRecords: [record])
        let channel = InertShellChannel()
        let tab = TerminalTab(
            id: record.id,
            hostID: record.hostID,
            hostName: record.hostName,
            session: TerminalSession(channel: channel),
            source: .persistent(providerID: record.providerID),
            reconnectDescriptor: .persistent(record.descriptor),
            automaticAlias: record.automaticAlias
        )

        store.add(tab)

        #expect(store.hostGroups.first?.tabs.map(\.id) == [record.id])
        #expect(store.hostGroups.first?.resumeRecords.isEmpty == true)
        #expect(store.hostGroups.first?.terminalCount == 1)
    }

    @Test("恢复记录按 Workspace 身份更新而不是重复追加")
    func upsertsResumeRecordByWorkspaceIdentity() {
        let first = makeResumeRecord(id: "first", workspaceID: "$1", name: "ops")
        let replacement = makeResumeRecord(id: "replacement", workspaceID: "$1", name: "production")
        let store = TerminalSessionStore(resumeRecords: [first])

        store.upsertResumeRecord(replacement)

        #expect(store.resumeRecords == [replacement])
    }

    @Test("关闭一台主机的会话不影响其它主机")
    func closeAllForHostLeavesOtherHosts() async {
        let store = TerminalSessionStore()
        store.add(makeTab(hostID: "h1", name: "web"))
        store.add(makeTab(hostID: "h1", name: "web"))
        let other = makeTab(hostID: "h2", name: "db")
        store.add(other)

        await store.closeAll(forHost: "h1")

        #expect(store.tabs.map(\.id) == [other.id])
    }
}
