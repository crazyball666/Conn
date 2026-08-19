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
        monitor.start(host: host)
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
