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
                ? "已向 \(target.command)（PID \(target.pid)）发送结束信号"
                : "结束 \(target.command) 失败：\(result.stderrText)"
        } catch {
            actionMessage = "结束进程失败：\(error.localizedDescription)"
        }
    }
}
