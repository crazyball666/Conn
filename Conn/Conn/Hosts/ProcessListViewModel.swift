import ConnAnalytics
import ConnKit
import ConnMonitor
import ConnSSH
import Foundation
import Observation

/// 进程页状态与生命周期。与主机概览监控完全独立，只共享 SSH 连接池。
@Observable
@MainActor
final class ProcessListViewModel {
    let monitor: ProcessMonitor

    private let host: Host
    private let connectionManager: ConnectionManager

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        connectionManager = dependencies.connectionManager
        monitor = ProcessMonitor(connectionManager: dependencies.connectionManager)
    }

    var processes: [RemoteProcess] { monitor.processes }
    var errorText: String? { monitor.errorText }
    var isLoading: Bool { monitor.isLoading }
    var capabilityState: CapabilityState? { monitor.capabilityState }

    var capabilityMessage: String? {
        switch capabilityState {
        case .none, .supported:
            return nil
        case .degraded:
            return L("部分进程详情不可用")
        case let .unavailable(issue):
            return issue.code == .permissionDenied ? L("权限不足，无法读取完整进程信息") : L("进程采集暂不可用")
        case .unsupported:
            return L("当前主机平台暂不支持进程采集")
        }
    }

    func appear() {
        let started = Date()
        monitor.start(host: host)
        Task { [weak self] in
            guard let self else { return }
            // start() 立即置 isLoading；等首轮采集结束再上报，避免把自动刷新算成多次打开。
            for _ in 0..<150 where monitor.isLoading {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            var properties: [AnalyticsProperty: String] = [
                .success: monitor.errorText == nil ? "true" : "false",
                .processCountBucket: Analytics.countBucket(monitor.processes.count),
                .latencyMsBucket: Analytics.durationBucket(
                    milliseconds: Int(Date().timeIntervalSince(started) * 1000)
                ),
            ]
            if monitor.errorText != nil {
                properties[.errorCategory] = "process_collection"
            }
            Analytics.shared.track(.processListOpened, properties)
        }
    }

    func disappear() {
        monitor.stop()
    }

    func retryProcesses() async {
        await monitor.refresh(host: host)
    }

    /// 向进程发 SIGTERM。进程列表和详情页共用该入口。
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
