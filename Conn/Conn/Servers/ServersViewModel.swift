import ConnKit
import ConnMonitor
import ConnUI
import Foundation
import Observation

/// 「服务器」页 ViewModel（原「仪表盘」+「主机」合并）。
///
/// 一屏搞定观测与管理：健康视图为主（实时指标卡、故障置顶），同页搜索 /
/// 标签筛选 / 增删改查。合并动机——两页看的本就是同一堆主机，分屏是设计师
/// 脑中的「监控 vs 管理」抽象，小规模场景下用户只感到重复（简单优先）。
///
/// `cards` 是计算属性，读取 `monitor.metrics` / `monitor.errors`——在 View body
/// 中求值，Observation 追踪这些访问，采集一有更新卡片即刷新。
@Observable
@MainActor
final class ServersViewModel {
    private(set) var hosts: [Host] = []
    private(set) var errorMessage: String?
    var searchText = ""
    var selectedTag: String?

    private let hostStore: any HostRepository
    /// 采集调度。View 在 appear/disappear 控制生命周期。
    let monitor: MonitorScheduler

    /// 免费版主机上限。Phase 10 接入 ConnEntitlement.Gate 前先硬编码。
    let freeHostLimit = 3

    init(hostStore: any HostRepository, monitor: MonitorScheduler) {
        self.hostStore = hostStore
        self.monitor = monitor
    }

    // MARK: - 生命周期

    /// 进入页面：读主机 + 启动 30s 轮询。
    func appear() {
        load()
        monitor.startDashboard(hosts: hosts)
    }

    /// 离开页面：停止轮询（页面不可见即停，方案 §4.3）。
    func disappear() {
        monitor.stop()
    }

    func load() {
        do {
            hosts = try hostStore.allHosts()
            errorMessage = nil
        } catch {
            errorMessage = "读取主机失败：\(error.localizedDescription)"
            hosts = []
        }
    }

    /// 下拉刷新：重读主机 + 立即巡检一轮。
    func refresh() async {
        load()
        await monitor.scanNow(hosts: hosts)
    }

    /// 软删除（墓碑），可随时重新添加，不影响服务器本身。
    func delete(_ host: Host) {
        try? hostStore.softDelete(id: host.id)
        load()
    }

    // MARK: - 派生

    /// 经搜索 / 标签筛选、按故障优先排序的健康卡。
    var cards: [HealthCard.Model] {
        let filtered: [Host] = hosts.filter { matches($0) }
        let mapped: [HealthCard.Model] = filtered.map { card(for: $0) }
        return mapped.sorted(by: Self.severityFirst)
    }

    /// 全部出现过的标签，去重排序，供筛选 chip。
    var allTags: [String] {
        Array(Set(hosts.flatMap(\.tags))).sorted()
    }

    var totalCount: Int { hosts.count }

    /// 异常台数（含实时严重度）。用于顶部概览胶囊。
    var abnormalCount: Int {
        let mapped: [HealthCard.Model] = hosts.map { card(for: $0) }
        return mapped.count { $0.status == .crit || $0.status == .warn || $0.status == .offline }
    }

    /// 是否已达免费版上限（超出时新增触发 Paywall——Phase 10 接）。
    var isAtFreeLimit: Bool { hosts.count >= freeHostLimit }

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
        let matchesTag = selectedTag.map { host.tags.contains($0) } ?? true
        return matchesSearch && matchesTag
    }

    private func card(for host: Host) -> HealthCard.Model {
        let metrics = monitor.metrics[host.id]
        let error = monitor.errors[host.id]
        let status = presentationStatus(metrics: metrics, hasError: error != nil)
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
            issue: status == .offline ? (error ?? L("连接失败，下拉重试")) : nil,
            note: host.note
        )
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

    /// 异常主机置顶（PRD §5.4：红黄绿，故障优先可见）。
    private static func severityFirst(_ lhs: HealthCard.Model, _ rhs: HealthCard.Model) -> Bool {
        func rank(_ status: ConnHealthStatus) -> Int {
            switch status {
            case .crit: 0
            case .offline: 1
            case .warn: 2
            case .unknown: 3
            case .ok: 4
            }
        }
        let (left, right) = (rank(lhs.status), rank(rhs.status))
        return left == right ? lhs.name < rhs.name : left < right
    }
}
