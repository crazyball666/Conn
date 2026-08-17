import ConnKit
import ConnMonitor
import Foundation
import Observation

/// 内存图的三条独立实际百分比。三者直接来自远端采集字段，不为凑满 100%
/// 相互推导；Linux 的 MemAvailable 与 cache/free 口径本来就可能有交叠。
struct MemoryChartValues: Equatable, Sendable {
    let used: Double?
    let cache: Double?
    let free: Double?

    init?(metrics: HostMetrics) {
        guard let total = metrics.memTotalBytes, total > 0 else { return nil }
        used = Self.percent(metrics.memUsedBytes, total: total)
        cache = Self.percent(metrics.memBuffersCache, total: total)
        free = Self.percent(metrics.memFree, total: total)
    }

    private static func percent(_ value: Double?, total: Double) -> Double? {
        value.map { min(100, max(0, $0 / total * 100)) }
    }
}

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
    /// CPU 八类时间占比历史，供指标独立显示/隐藏。
    private(set) var cpuCategoryHistory = CPUCategoryHistory()
    private(set) var memUsedHistory: [TrendSample] = []
    private(set) var memCacheHistory: [TrendSample] = []
    private(set) var memFreeHistory: [TrendSample] = []
    private(set) var netRxHistory: [TrendSample] = []
    private(set) var netTxHistory: [TrendSample] = []
    private(set) var ioReadHistory: [TrendSample] = []
    private(set) var ioWriteHistory: [TrendSample] = []
    private let maxPoints = TrendViewport.retainedSampleCount
    private var nextSampleSequence = 0

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        let monitor = MonitorScheduler(connectionManager: dependencies.connectionManager)
        self.monitor = monitor
        monitor.onMetricsUpdated = { [weak self] metrics in
            guard let self, metrics.hostID == self.host.id else { return }
            self.record(metrics)
        }
    }

    /// 本次采集结果（读 `monitor.metrics` → 在 body 中被 Observation 追踪，实时刷新）。
    var latest: HostMetrics? { monitor.metrics[host.id] }
    var errorText: String? { monitor.errors[host.id] }
    var capabilityMessage: String? {
        guard let state = latest?.capabilityState else { return nil }
        switch state {
        case .supported:
            return nil
        case .degraded:
            return L("部分主机指标不可用")
        case .unavailable:
            return L("主机指标采集暂不可用")
        case .unsupported:
            return L("当前主机平台暂不支持指标采集")
        }
    }

    /// 每来一次新采样记录实际采集到的指标。只把实际采集到的样本写入历史；
    /// 首采缺失就保持空白，不制造一个看起来像真实读数的零点。后续能力缺失同样
    /// 不补零，避免平台能力降级在图表中表现为瞬时归零。
    private func record(_ metrics: HostMetrics) {
        let sequence = nextSampleSequence
        nextSampleSequence += 1
        recordCPUBreakdown(metrics.cpuBreakdown, sequence: sequence)
        recordMemory(MemoryChartValues(metrics: metrics), sequence: sequence)
        if let rx = metrics.netRxRate, let tx = metrics.netTxRate {
            append(&netRxHistory, rx, sequence: sequence)
            append(&netTxHistory, tx, sequence: sequence)
        }
        if let read = metrics.ioReadRate, let write = metrics.ioWriteRate {
            append(&ioReadHistory, read, sequence: sequence)
            append(&ioWriteHistory, write, sequence: sequence)
        }
    }

    private func recordCPUBreakdown(_ breakdown: CPUBreakdown?, sequence: Int) {
        if let breakdown {
            cpuCategoryHistory.append(breakdown, sequence: sequence, limit: maxPoints)
        }
    }

    private func recordMemory(_ values: MemoryChartValues?, sequence: Int) {
        guard let values else { return }
        append(&memUsedHistory, values.used, sequence: sequence)
        append(&memCacheHistory, values.cache, sequence: sequence)
        append(&memFreeHistory, values.free, sequence: sequence)
    }

    private func append(_ array: inout [TrendSample], _ value: Double?, sequence: Int) {
        guard let value else { return }
        append(&array, value, sequence: sequence)
    }

    private func append(_ array: inout [TrendSample], _ value: Double, sequence: Int) {
        array.append(TrendSample(sequence: sequence, value: value))
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
