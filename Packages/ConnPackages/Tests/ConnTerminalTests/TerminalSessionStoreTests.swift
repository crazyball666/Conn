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
}
