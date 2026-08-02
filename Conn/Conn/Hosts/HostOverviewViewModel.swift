import ConnKit
import ConnMonitor
import Foundation
import Observation

/// 单机概览 ViewModel（Phase 7）。
///
/// 持有**独立的** `MonitorScheduler`（3s 高频，只采这一台），与仪表盘的共享调度器
/// 解耦——避免导航 push/pop 时两处 start/stop 互相打断。会话仍走同一
/// `ConnectionManager` 连接池，不会重复握手。
@Observable
@MainActor
final class HostOverviewViewModel {
    let monitor: MonitorScheduler

    private let host: Host
    /// 折线图用的滚动历史（每 3s 一点，保留最近 `maxPoints` 个）。
    private(set) var cpuHistory: [Double] = []
    /// 各逻辑核使用率历史，`coreHistories[核序]` = 该核的时间序列。
    private(set) var coreHistories: [[Double]] = []
    /// CPU 八类时间占比历史，供指标独立显示/隐藏。
    private(set) var cpuCategoryHistory = CPUCategoryHistory()
    private(set) var memHistory: [Double] = []
    /// 内存三段占比历史（已用 / 缓存 / 空闲，% of total，堆叠到 100）。
    private(set) var memUsedHistory: [Double] = []
    private(set) var memCacheHistory: [Double] = []
    private(set) var memFreeHistory: [Double] = []
    private(set) var netRxHistory: [Double] = []
    private(set) var netTxHistory: [Double] = []
    private(set) var ioReadHistory: [Double] = []
    private(set) var ioWriteHistory: [Double] = []
    private let maxPoints = 40

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        monitor = MonitorScheduler(connectionManager: dependencies.connectionManager)
    }

    /// 本次采集结果（读 `monitor.metrics` → 在 body 中被 Observation 追踪，实时刷新）。
    var latest: HostMetrics? { monitor.metrics[host.id] }
    var errorText: String? { monitor.errors[host.id] }

    /// 每来一次新采样，把各指标追加进历史（缺失记 0）。View 在 `latest` 变化时调用。
    func record() {
        guard let metrics = latest else { return }
        append(&cpuHistory, metrics.cpu ?? 0)
        recordPerCore(metrics.cpuPerCore)
        recordCPUBreakdown(metrics.cpuBreakdown)
        append(&memHistory, metrics.mem ?? 0)
        recordMemBreakdown(metrics)
        append(&netRxHistory, metrics.netRxRate ?? 0)
        append(&netTxHistory, metrics.netTxRate ?? 0)
        append(&ioReadHistory, metrics.ioReadRate ?? 0)
        append(&ioWriteHistory, metrics.ioWriteRate ?? 0)
    }

    private func recordCPUBreakdown(_ breakdown: CPUBreakdown?) {
        guard let breakdown else { return }
        cpuCategoryHistory.append(breakdown, limit: maxPoints)
    }

    private func recordPerCore(_ cores: [Double]?) {
        guard let cores, !cores.isEmpty else { return }
        if coreHistories.count != cores.count {
            coreHistories = Array(repeating: [], count: cores.count)
        }
        for (index, value) in cores.enumerated() {
            append(&coreHistories[index], value)
        }
    }

    private func recordMemBreakdown(_ metrics: HostMetrics) {
        guard let total = metrics.memTotalBytes, total > 0 else { return }
        let cache = metrics.memBuffersCache ?? 0
        let free = metrics.memFree ?? 0
        let used = max(0, total - cache - free)
        append(&memUsedHistory, used / total * 100)
        append(&memCacheHistory, cache / total * 100)
        append(&memFreeHistory, free / total * 100)
    }

    private func append(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > maxPoints {
            array.removeFirst(array.count - maxPoints)
        }
    }

    func appear() { monitor.startDetail(host: host) }
    func disappear() { monitor.stop() }

    /// 概览可见时附带系统名/CPU 型号/TCP 重传/网卡，并立即补采一次。
    func setOverviewSegmentActive(_ active: Bool) {
        monitor.wantsExtended = active
        if active {
            Task { await monitor.refreshDetail(host: host) }
        }
    }

}
