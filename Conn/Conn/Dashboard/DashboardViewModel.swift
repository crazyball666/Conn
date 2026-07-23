import ConnKit
import ConnMonitor
import ConnUI
import Foundation
import Observation

/// 仪表盘 ViewModel。
///
/// 把主机列表与 `MonitorScheduler` 的实时采集结果合并成 HealthCard 展示模型。
/// `cards` 是计算属性，读取 `monitor.metrics` / `monitor.errors`——因在 View body
/// 中求值，Observation 会追踪这些访问，采集一有更新卡片即刷新。
@Observable
@MainActor
final class DashboardViewModel {
    private(set) var hosts: [Host] = []
    private(set) var errorMessage: String?

    private let hostStore: any HostRepository
    /// 采集调度。对外暴露供 View 在 appear/disappear 控制生命周期。
    let monitor: MonitorScheduler

    init(hostStore: any HostRepository, monitor: MonitorScheduler) {
        self.hostStore = hostStore
        self.monitor = monitor
    }

    var cards: [HealthCard.Model] {
        hosts.map(card(for:)).sorted(by: Self.severityFirst)
    }

    var totalCount: Int { hosts.count }

    /// 按 id 取回主机（卡片点击 → 详情导航）。
    func host(forID id: String) -> Host? {
        hosts.first { $0.id == id }
    }

    var abnormalCount: Int {
        cards.count { $0.status == .crit || $0.status == .warn || $0.status == .offline }
    }

    var lastScanText: String {
        guard let lastScanAt = monitor.lastScanAt else { return "尚未巡检" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return "最后巡检 " + formatter.localizedString(for: lastScanAt, relativeTo: Date())
    }

    // MARK: - 生命周期

    /// 进入仪表盘：读主机 + 启动 30s 轮询。
    func appear() {
        load()
        monitor.startDashboard(hosts: hosts)
    }

    /// 离开仪表盘：停止轮询（页面不可见即停，方案 §4.3）。
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

    // MARK: - 映射

    private func card(for host: Host) -> HealthCard.Model {
        let metrics = monitor.metrics[host.id]
        let error = monitor.errors[host.id]
        let status = presentationStatus(host: host, metrics: metrics, hasError: error != nil)
        return HealthCard.Model(
            id: host.id,
            name: host.name,
            address: host.displayAddress,
            status: status,
            cpu: metrics?.cpu,
            memory: metrics?.mem,
            disk: metrics?.disk,
            issue: status == .offline ? (error ?? "连接失败，下拉重试") : nil
        )
    }

    /// 实时采集优先；无采集但有错误 → 离线；两者皆无 → 未知（首采尚未回来）。
    private func presentationStatus(host: Host, metrics: HostMetrics?, hasError: Bool) -> ConnHealthStatus {
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

    /// 异常主机置顶（PRD §5.4：仪表盘首页红黄绿，故障优先可见）。
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
