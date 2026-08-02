import ConnKit
import ConnMonitor
import ConnSSH
import ConnUI
import Foundation
import Observation

/// 「服务器」页 ViewModel（原「仪表盘」+「主机」合并）。
///
/// 一屏搞定观测与管理：健康视图为主（实时指标卡），同页搜索 /
/// 分组筛选 / 增删改查。合并动机——两页看的本就是同一堆主机，分屏是设计师
/// 脑中的「监控 vs 管理」抽象，小规模场景下用户只感到重复（简单优先）。
///
/// `cards` 是计算属性，读取 `monitor.metrics` / `monitor.errors`——在 View body
/// 中求值，Observation 追踪这些访问，采集一有更新卡片即刷新。
@Observable
@MainActor
final class ServersViewModel {
    private(set) var hosts: [Host] = []
    private(set) var groups: [HostGroup] = []
    private(set) var errorMessage: String?
    var searchText = ""
    /// 当前选中的分组 id；nil 表示「全部」。
    var selectedGroupID: String?

    private let hostStore: any HostRepository
    private let groupStore: any HostGroupRepository
    /// 采集调度。View 在 appear/disappear 控制生命周期。
    let monitor: MonitorScheduler

    init(
        hostStore: any HostRepository,
        groupStore: any HostGroupRepository,
        monitor: MonitorScheduler
    ) {
        self.hostStore = hostStore
        self.groupStore = groupStore
        self.monitor = monitor
    }

    // MARK: - 生命周期

    /// 进入页面：读主机 + 启动轮询（间隔由设置页决定，默认 30s）。
    func appear(interval: Duration = .seconds(30)) {
        load()
        monitor.startDashboard(hosts: hosts, interval: interval)
    }

    /// 离开页面：停止轮询（页面不可见即停，方案 §4.3）。
    func disappear() {
        monitor.stop()
    }

    func load() {
        errorMessage = nil
        do {
            hosts = try hostStore.allHosts()
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch {
            errorMessage = String(format: L("读取主机失败：%@"), error.friendlyDiagnosis)
            hosts = []
            groups = []
        }
    }

    /// 下拉刷新：重读主机 + 立即巡检一轮。
    func refresh() async {
        load()
        await monitor.scanNow(hosts: hosts)
    }

    /// 真删除，不可恢复。只影响本地记录，不影响服务器本身。
    func delete(_ host: Host) {
        errorMessage = nil
        try? hostStore.delete(id: host.id)
        load()
    }

    // MARK: - 派生

    /// 经搜索 / 分组筛选后的健康卡。
    ///
    /// **顺序完全照抄 `HostStore.allHosts()`（`sort_order ASC, name ASC`）**——
    /// 健康状态不参与排序：旧的「故障置顶」会让列表在采集期间持续跳动，
    /// 且尚未连上（unknown）的主机会排在已连上（ok）的前面。
    var cards: [HealthCard.Model] {
        hosts.filter { matches($0) }.map { card(for: $0) }
    }

    var totalCount: Int { hosts.count }

    /// 异常台数（含实时严重度）。用于顶部概览胶囊。
    var abnormalCount: Int {
        let mapped: [HealthCard.Model] = hosts.map { card(for: $0) }
        return mapped.count { $0.status == .crit || $0.status == .warn || $0.status == .offline }
    }

    var lastScanText: String {
        guard let lastScanAt = monitor.lastScanAt else { return L("尚未巡检") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = ConnLanguage.currentLocale
        formatter.unitsStyle = .short
        return L("最后巡检 ") + formatter.localizedString(for: lastScanAt, relativeTo: Date())
    }

    /// 按 id 取回主机（卡片点击 → 详情导航；上下文菜单编辑/删除）。
    func host(forID id: String) -> Host? {
        hosts.first { $0.id == id }
    }

    // MARK: - 映射

    private func matches(_ host: Host) -> Bool {
        let matchesSearch = searchText.isEmpty
            || host.name.localizedCaseInsensitiveContains(searchText)
            || host.address.localizedCaseInsensitiveContains(searchText)
        return matchesSearch && matchesGroup(host)
    }

    /// 选中的分组 id 解析不到现存分组时按「全部」处理，
    /// 防御分组从其他路径消失后筛选条件把整张列表滤空。
    private func matchesGroup(_ host: Host) -> Bool {
        guard let id = selectedGroupID, groups.contains(where: { $0.id == id }) else { return true }
        return host.groupIDs.contains(id)
    }

    private func card(for host: Host) -> HealthCard.Model {
        let metrics = monitor.metrics[host.id]
        let error = monitor.errors[host.id]
        let phase = monitor.phases[host.id] ?? .idle
        let status = presentationStatus(metrics: metrics, hasError: error != nil)
        let loadState: HealthCard.LoadState
        if metrics != nil {
            loadState = .loaded
        } else if let error, !error.isEmpty {
            loadState = .failed(error)
        } else if error != nil {
            loadState = .failed(L("连接失败，下拉重试"))
        } else {
            loadState = .loading
        }
        return HealthCard.Model(
            id: host.id,
            name: host.name,
            address: host.displayAddress,
            status: status,
            cpu: metrics?.cpu,
            memory: metrics?.mem,
            disk: metrics?.disk,
            coresText: MetricFormat.cores(metrics?.cpuCores),
            memTotalText: MetricFormat.compactBytes(metrics?.memTotalBytes),
            diskTotalText: MetricFormat.compactBytes(metrics?.diskTotalBytes),
            net: metrics.map { flow(upRate: $0.netTxRate, upTotal: $0.netTx, downRate: $0.netRxRate, downTotal: $0.netRx) },
            io: metrics.map { flow(upRate: $0.ioWriteRate, upTotal: $0.ioWriteBytes, downRate: $0.ioReadRate, downTotal: $0.ioReadBytes) },
            uptimeText: metrics?.uptimeSeconds.map { MetricFormat.compactUptime($0) },
            loadText: metrics?.load1.map { String(format: "%.2f", $0) },
            loadState: loadState,
            note: host.note,
            collectPhase: collectPhase(phase)
        )
    }

    /// 领域三态 → 展示层三态。ConnUI 刻意不依赖 ConnMonitor，映射由 Feature 层
    /// 承担（与 `presentationStatus` 同理）；一一对应，不做任何合并或丢弃。
    private func collectPhase(_ phase: CollectPhase) -> ConnCollectPhase {
        switch phase {
        case .idle: .idle
        case .collecting: .collecting
        case .reconnecting: .reconnecting
        }
    }

    /// 组装网络/IO 的 ↑↓（速率·总量）已格式化读数。
    private func flow(upRate: Double?, upTotal: Int64?, downRate: Double?, downTotal: Int64?) -> HealthCard.Flow {
        HealthCard.Flow(
            upRate: MetricFormat.compactBytes(upRate),
            upTotal: MetricFormat.compactBytes(upTotal),
            downRate: MetricFormat.compactBytes(downRate),
            downTotal: MetricFormat.compactBytes(downTotal)
        )
    }

    /// 实时采集优先；无采集但有错误 → 离线；两者皆无 → 未知（首采尚未回来）。
    private func presentationStatus(metrics: HostMetrics?, hasError: Bool) -> ConnHealthStatus {
        if let metrics {
            switch metrics.severity {
            case .ok: return .ok
            case .warn: return .warn
            case .crit: return .crit
            case .unknown: return .unknown
            }
        }
        return hasError ? .offline : .unknown
    }

    // MARK: - 分组

    func addGroup(_ name: String) {
        errorMessage = nil
        do {
            let trimmed = try GroupListEditor.validate(name: name, against: groups.map(\.name))
            try groupStore.save(HostGroup(
                name: trimmed,
                sortOrder: GroupListEditor.nextSortOrder(after: groups.map(\.sortOrder))
            ))
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch let failure as GroupListEditor.Failure {
            errorMessage = failure.message
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func renameGroup(id: String, to name: String) {
        guard var group = groups.first(where: { $0.id == id }) else { return }
        errorMessage = nil
        do {
            let others = groups.filter { $0.id != id }.map(\.name)
            group.name = try GroupListEditor.validate(name: name, against: others)
            try groupStore.save(group)
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch let failure as GroupListEditor.Failure {
            errorMessage = failure.message
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    /// 删除分组只解除归属，主机本身不受影响（成员行由外键级联清理）。
    func deleteGroup(id: String) {
        errorMessage = nil
        do {
            try groupStore.delete(id: id)
            if selectedGroupID == id { selectedGroupID = nil }
            load()
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
