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

    private let host: Host
    private let connectionManager: ConnectionManager

    /// 折线图用的滚动历史（每 3s 一点，保留最近 `maxPoints` 个）。
    private(set) var cpuHistory: [Double] = []
    /// 各逻辑核使用率历史，`coreHistories[核序]` = 该核的时间序列。
    private(set) var coreHistories: [[Double]] = []
    /// CPU 各类占比历史（用户/系统/iowait/其他/空闲，% 堆叠到 100）。
    private(set) var cpuUserHistory: [Double] = []
    private(set) var cpuSystemHistory: [Double] = []
    private(set) var cpuIowaitHistory: [Double] = []
    private(set) var cpuOtherHistory: [Double] = []
    private(set) var cpuIdleHistory: [Double] = []
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
        append(&cpuUserHistory, breakdown.user)
        append(&cpuSystemHistory, breakdown.system)
        append(&cpuIowaitHistory, breakdown.iowait)
        append(&cpuOtherHistory, breakdown.nice + breakdown.irq + breakdown.softirq + breakdown.steal)
        append(&cpuIdleHistory, breakdown.idle)
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

    /// 全量进程（排序/筛选交给进程段 UI）。仅「进程」段激活时才有值（见 `setProcessSegmentActive`）。
    var processes: [RemoteProcess] {
        latest?.processes ?? []
    }

    /// 进程段已激活但进程尚未到手（首次加载中）。活机总有进程，故「激活且空」即视为加载中。
    var processesLoading: Bool {
        monitor.wantsProcesses && processes.isEmpty
    }

    func appear() { monitor.startDetail(host: host) }
    func disappear() { monitor.stop() }

    /// 进入/离开「概览」段：开关采集脚本里的详情段（系统名/CPU 型号/TCP 重传/网卡）。
    /// 其它段（进程/文件/Docker/日志）只需核心指标撑起顶部状态胶囊，不采这些。
    func setOverviewSegmentActive(_ active: Bool) {
        monitor.wantsExtended = active
        if active {
            Task { await monitor.refreshDetail(host: host) }
        }
    }

    /// 进入/离开「进程」段：开关采集脚本里的 `ps`——概览不采进程以省流量。
    /// 激活时立刻补采一次，别等下一个 3s 轮询才出进程。
    func setProcessSegmentActive(_ active: Bool) {
        monitor.wantsProcesses = active
        if active {
            Task { await monitor.refreshDetail(host: host) }
        }
    }

    /// 向进程发 SIGTERM，返回结果文案。二次确认与结果提示由各视图自持有本地状态呈现
    /// ——详情页是列表推入的子层，集中在祖先视图的对话框在被覆盖时呈现不可靠。
    func performKill(_ process: RemoteProcess) async -> String {
        do {
            let session = try await connectionManager.session(for: host)
            let result = try await ProcessControl.kill(pid: process.pid, on: session)
            return result.isSuccess
                ? String(format: L("已向 %@（PID %d）发送结束信号"), process.command, process.pid)
                : String(format: L("结束 %@ 失败：%@"), process.command, result.stderrText)
        } catch {
            return String(format: L("结束进程失败：%@"), error.friendlyDiagnosis)
        }
    }
}
