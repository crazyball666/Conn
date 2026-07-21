import ConnSSH
import Foundation
import Observation

/// 一个活跃终端会话的句柄（会话中心 S4 的一行）。
public struct TerminalTab: Identifiable, Sendable {
    public let id: String
    public let hostID: String
    public let hostName: String
    public let session: TerminalSession

    public init(id: String = UUID().uuidString, hostID: String, hostName: String, session: TerminalSession) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.session = session
    }
}

/// 多会话管理（技术方案 §4.2：多标签并行，后台保持）。
///
/// 会话生命周期与 UI 解耦——切走某个标签不断连，会话留在 store 里继续存活。
/// UI 层（会话中心）观察此 store 渲染标签、切换当前会话。
@Observable
@MainActor
public final class TerminalSessionStore {
    public private(set) var tabs: [TerminalTab] = []
    public var currentTabID: String?

    public init() {}

    public var currentTab: TerminalTab? {
        tabs.first { $0.id == currentTabID }
    }

    /// 加入一个新会话并设为当前。
    public func add(_ tab: TerminalTab) {
        tabs.append(tab)
        currentTabID = tab.id
    }

    /// 关闭并移除一个会话（断开其连接）。
    public func close(_ tabID: String) async {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs.remove(at: index)
        await tab.session.close()
        // 关掉当前标签时，切到相邻的一个
        if currentTabID == tabID {
            currentTabID = tabs.last?.id
        }
    }

    /// 关闭全部（App 退出或断开所有）。
    public func closeAll() async {
        let current = tabs
        tabs.removeAll()
        currentTabID = nil
        for tab in current {
            await tab.session.close()
        }
    }

    /// 是否已有连到某主机的会话（避免重复开）。
    public func existingTab(forHost hostID: String) -> TerminalTab? {
        tabs.first { $0.hostID == hostID }
    }
}
