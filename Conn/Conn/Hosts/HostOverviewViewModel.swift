import ConnKit
import ConnMonitor
import ConnSSH
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
    /// 待确认结束的进程（二次确认，PRD §5.4）。
    var killTarget: RemoteProcess?
    var actionMessage: String?

    private let host: Host
    private let connectionManager: ConnectionManager

    /// 折线图用的滚动历史（每 3s 一点，保留最近 `maxPoints` 个）。
    private(set) var cpuHistory: [Double] = []
    /// 各逻辑核使用率历史，`coreHistories[核序]` = 该核的时间序列。
    private(set) var coreHistories: [[Double]] = []
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
        connectionManager = dependencies.connectionManager
        monitor = MonitorScheduler(
            connectionManager: dependencies.connectionManager,
            store: dependencies.metricStore
        )
    }

    /// 本次采集结果（读 `monitor.metrics` → 在 body 中被 Observation 追踪，实时刷新）。
    var latest: HostMetrics? { monitor.metrics[host.id] }
    var errorText: String? { monitor.errors[host.id] }

    /// 每来一次新采样，把各指标追加进历史（缺失记 0）。View 在 `latest` 变化时调用。
    func record() {
        guard let metrics = latest else { return }
        append(&cpuHistory, metrics.cpu ?? 0)
        recordPerCore(metrics.cpuPerCore)
        append(&memHistory, metrics.mem ?? 0)
        recordMemBreakdown(metrics)
        append(&netRxHistory, metrics.netRxRate ?? 0)
        append(&netTxHistory, metrics.netTxRate ?? 0)
        append(&ioReadHistory, metrics.ioReadRate ?? 0)
        append(&ioWriteHistory, metrics.ioWriteRate ?? 0)
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

    /// 进程列表取 CPU 前 8（进程视角 P0）。
    var topProcesses: [RemoteProcess] {
        Array((latest?.processes ?? []).prefix(8))
    }

    func appear() { monitor.startDetail(host: host) }
    func disappear() { monitor.stop() }

    func requestKill(_ process: RemoteProcess) {
        killTarget = process
    }

    /// 确认后发 SIGTERM。失败进 `actionMessage` 提示。
    func confirmKill() async {
        guard let target = killTarget else { return }
        killTarget = nil
        do {
            let session = try await connectionManager.session(for: host)
            let result = try await ProcessControl.kill(pid: target.pid, on: session)
            actionMessage = result.isSuccess
                ? String(format: L("已向 %@（PID %d）发送结束信号"), target.command, target.pid)
                : String(format: L("结束 %@ 失败：%@"), target.command, result.stderrText)
        } catch {
            actionMessage = "结束进程失败：\(error.localizedDescription)"
        }
    }
}
