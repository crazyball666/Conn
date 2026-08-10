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
    var capabilityMessage: String? {
        guard let state = latest?.capabilityState else { return nil }
        switch state {
        case .supported:
            nil
        case .degraded:
            L("部分主机指标不可用")
        case .unavailable:
            L("主机指标采集暂不可用")
        case .unsupported:
            L("当前主机平台暂不支持指标采集")
        }
    }

    /// 每来一次新采样，只记录实际采集到的指标。缺失值不能伪装成 0，
    /// 否则平台能力降级会在图表中表现为不存在的瞬时归零。
    func record() {
        guard let metrics = latest else { return }
        if let cpu = metrics.cpu { append(&cpuHistory, cpu) }
        recordPerCore(metrics.cpuPerCore)
        recordCPUBreakdown(metrics.cpuBreakdown)
        if let mem = metrics.mem { append(&memHistory, mem) }
        recordMemBreakdown(metrics)
        if let rx = metrics.netRxRate, let tx = metrics.netTxRate {
            append(&netRxHistory, rx)
            append(&netTxHistory, tx)
        }
        if let read = metrics.ioReadRate, let write = metrics.ioWriteRate {
            append(&ioReadHistory, read)
            append(&ioWriteHistory, write)
        }
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
        guard let total = metrics.memTotalBytes, total > 0,
              let cache = metrics.memBuffersCache,
              let free = metrics.memFree
        else { return }
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
