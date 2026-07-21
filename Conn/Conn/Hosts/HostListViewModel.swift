import ConnKit
import ConnUI
import Foundation
import Observation

/// 主机列表 ViewModel（原型 S2）。
@Observable
@MainActor
final class HostListViewModel {
    private(set) var hosts: [Host] = []
    private(set) var groups: [HostGroup] = []
    var searchText = ""
    var selectedTag: String?

    private let hostStore: any HostRepository
    private let groupStore: any HostGroupRepository

    /// 免费版主机上限。Phase 10 接入 ConnEntitlement.Gate 前先硬编码。
    let freeHostLimit = 3

    init(hostStore: any HostRepository, groupStore: any HostGroupRepository) {
        self.hostStore = hostStore
        self.groupStore = groupStore
    }

    func load() {
        hosts = (try? hostStore.allHosts()) ?? []
        groups = (try? groupStore.allGroups()) ?? []
    }

    func delete(_ host: Host) {
        try? hostStore.softDelete(id: host.id)
        load()
    }

    // MARK: - 派生

    /// 全部出现过的标签，去重排序，供筛选 chip。
    var allTags: [String] {
        Array(Set(hosts.flatMap(\.tags))).sorted()
    }

    /// 经搜索与标签筛选后的主机。
    var filteredHosts: [Host] {
        hosts.filter { host in
            let matchesSearch = searchText.isEmpty
                || host.name.localizedCaseInsensitiveContains(searchText)
                || host.address.localizedCaseInsensitiveContains(searchText)
            let matchesTag = selectedTag.map { host.tags.contains($0) } ?? true
            return matchesSearch && matchesTag
        }
    }

    /// 是否已达免费版上限（超出时新增触发 Paywall——Phase 10 接）。
    var isAtFreeLimit: Bool {
        hosts.count >= freeHostLimit
    }

    /// 把主机的健康状态映射到展示层枚举。
    func presentationStatus(_ host: Host) -> ConnHealthStatus {
        switch host.status {
        case .ok: .ok
        case .warn: .warn
        case .crit: .crit
        case .offline: .offline
        case .unknown: .unknown
        }
    }

    /// 主机所属分组名（无则「未分组」）。
    func groupName(for host: Host) -> String {
        guard let groupUUID = host.groupUUID,
              let group = groups.first(where: { $0.id == groupUUID })
        else { return "未分组" }
        return group.name
    }

    /// 主机列表按分组切片，用于分区展示。
    var groupedHosts: [(group: String, hosts: [Host])] {
        let grouped = Dictionary(grouping: filteredHosts) { groupName(for: $0) }
        return grouped
            .map { (group: $0.key, hosts: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.group < $1.group }
    }
}
