import ConnKit
import ConnMonitor
import ConnSSH
import Foundation
import Testing
@testable import Conn

private final class StubHostRepository: HostRepository, @unchecked Sendable {
    var hosts: [Host]

    init(hosts: [Host] = []) { self.hosts = hosts }

    func allHosts() throws -> [Host] { hosts }
    func host(id: String) throws -> Host? { hosts.first { $0.id == id } }
    func save(_ host: Host) throws {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }
    func delete(id: String) throws { hosts.removeAll { $0.id == id } }
}

/// 模拟 `host_group_membership` 的 `ON DELETE CASCADE`：删组时把成员 id 摘掉。
private final class StubHostGroupRepository: HostGroupRepository, @unchecked Sendable {
    var groups: [HostGroup]
    weak var hostStore: StubHostRepository?

    init(groups: [HostGroup] = []) { self.groups = groups }

    func allGroups() throws -> [HostGroup] { groups.sorted { $0.sortOrder < $1.sortOrder } }

    func save(_ group: HostGroup) throws {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }

    func delete(id: String) throws {
        groups.removeAll { $0.id == id }
        guard let hostStore else { return }
        for index in hostStore.hosts.indices {
            hostStore.hosts[index].groupIDs.removeAll { $0 == id }
        }
    }
}

@MainActor
struct ServersViewModelTests {
    private func makeViewModel(
        hosts: [Host] = [],
        groups: [HostGroup] = []
    ) -> (ServersViewModel, StubHostGroupRepository) {
        let hostStore = StubHostRepository(hosts: hosts)
        let groupStore = StubHostGroupRepository(groups: groups)
        groupStore.hostStore = hostStore
        // MockSSHTransport 与 ConnectionManager 的参数都有默认值，测试里不会真的连接。
        let monitor = MonitorScheduler(
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let viewModel = ServersViewModel(
            hostStore: hostStore,
            groupStore: groupStore,
            monitor: monitor
        )
        viewModel.load()
        return (viewModel, groupStore)
    }

    @Test("卡片顺序照抄仓库顺序，不受健康状态影响")
    func keepsRepositoryOrder() {
        let hosts = [
            Host(name: "c-host", address: "3", username: "r"),
            Host(name: "a-host", address: "1", username: "r"),
            Host(name: "b-host", address: "2", username: "r")
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts)

        #expect(viewModel.cards.map(\.name) == ["c-host", "a-host", "b-host"])
    }

    @Test("按分组筛选")
    func filtersByGroup() {
        let prod = HostGroup(name: "生产")
        let hosts = [
            Host(name: "web", address: "1", username: "r", groupIDs: [prod.id]),
            Host(name: "nas", address: "2", username: "r")
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts, groups: [prod])

        viewModel.selectedGroupID = prod.id

        #expect(viewModel.cards.map(\.name) == ["web"])
    }

    @Test("搜索与分组取交集")
    func combinesSearchAndGroup() {
        let prod = HostGroup(name: "生产")
        let hosts = [
            Host(name: "web-01", address: "1", username: "r", groupIDs: [prod.id]),
            Host(name: "api-02", address: "2", username: "r", groupIDs: [prod.id])
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts, groups: [prod])

        viewModel.selectedGroupID = prod.id
        viewModel.searchText = "api"

        #expect(viewModel.cards.map(\.name) == ["api-02"])
    }

    @Test("选中的分组 id 悬空时按「全部」处理")
    func danglingSelectionFallsBackToAll() {
        let hosts = [Host(name: "web", address: "1", username: "r")]
        let (viewModel, _) = makeViewModel(hosts: hosts)

        viewModel.selectedGroupID = "gone"

        #expect(viewModel.cards.count == 1)
    }

    @Test("删除当前选中的分组后回到「全部」")
    func deletingSelectedGroupResetsSelection() {
        let prod = HostGroup(name: "生产")
        let (viewModel, _) = makeViewModel(groups: [prod])
        viewModel.selectedGroupID = prod.id

        viewModel.deleteGroup(id: prod.id)

        #expect(viewModel.selectedGroupID == nil)
        #expect(viewModel.groups.isEmpty)
    }

    @Test("删除分组不影响组内主机")
    func deletingGroupKeepsHosts() {
        let prod = HostGroup(name: "生产")
        let hosts = [Host(name: "web", address: "1", username: "r", groupIDs: [prod.id])]
        let (viewModel, _) = makeViewModel(hosts: hosts, groups: [prod])

        viewModel.deleteGroup(id: prod.id)

        #expect(viewModel.cards.map(\.name) == ["web"])
    }

    @Test("重名分组被拒并写入错误消息")
    func rejectsDuplicateGroupName() {
        let (viewModel, groupStore) = makeViewModel(groups: [HostGroup(name: "生产")])

        viewModel.addGroup(" 生产 ")

        #expect(groupStore.groups.count == 1)
        #expect(viewModel.errorMessage == L("已存在同名分组"))
    }

    @Test("新增分组的排序权重递增")
    func newGroupGetsNextSortOrder() {
        let (viewModel, groupStore) = makeViewModel(groups: [HostGroup(name: "生产", sortOrder: 4)])

        viewModel.addGroup("测试")

        #expect(groupStore.groups.map(\.sortOrder).max() == 5)
    }

    @Test("重命名分组不影响成员关系")
    func renameKeepsMembership() {
        let prod = HostGroup(name: "旧名")
        let hosts = [Host(name: "web", address: "1", username: "r", groupIDs: [prod.id])]
        let (viewModel, groupStore) = makeViewModel(hosts: hosts, groups: [prod])
        viewModel.selectedGroupID = prod.id

        viewModel.renameGroup(id: prod.id, to: "新名")

        #expect(groupStore.groups.map(\.name) == ["新名"])
        #expect(viewModel.cards.map(\.name) == ["web"])
    }
}
