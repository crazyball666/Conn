// 仅 DEBUG 编译：演示/截图/冒烟数据源，不进入发行包。
#if DEBUG
import ConnKit
import ConnSSH
import ConnStore
import Foundation

/// 演示模式的数据源（技术方案 §4.10）。
///
/// 通过 `MockSSHTransport.dynamicResponder` 把假指标/容器/日志注入 Mock 引擎，
/// 无需任何服务器即可完整体验 Phase 7–9。数据生成逻辑放在 App 层（可 import
/// ConnMonitor/ConnOps），ConnSSH 只持一个闭包插槽，保持分层解耦。
enum DemoData {
    /// 演示故障机地址——指标发生器对它输出高 CPU/内存，仪表盘上呈红色故障态。
    static let faultHostAddress = "10.20.0.66"

    /// 跨调用保留累计量的指标发生器（CPU 差分需要单调递增的 jiffies）。
    private static let metrics = DemoMetricsEngine()

    /// 组装 Mock 行为：指标走动态发生器，日志流带 30ms 节流模拟跟随。
    /// Docker/日志/片段的响应在 Phase 8/9 由 `dockerResponse` / `logResponse` 扩展。
    static func behavior() -> MockSSHTransport.Behavior {
        let shouldFailConnection =
            ProcessInfo.processInfo.environment["CONN_SMOKE_PROCESS_FAILURE"] != nil
        let smokeExecDelay = Int(
            ProcessInfo.processInfo.environment["CONN_SMOKE_EXEC_DELAY_MS"] ?? "0"
        ) ?? 0
        return MockSSHTransport.Behavior(
            failConnect: shouldFailConnection
                ? .connectionRefused(endpoint: SSHEndpoint(host: faultHostAddress))
                : nil,
            dynamicResponder: { command, endpoint in
                if command == RemotePlatformDetector.posixCommand {
                    return .init(stdout: platformProfileOutput)
                }
                switch command.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "command -v sh":
                    return .init(stdout: "/bin/sh\n")
                case "command -v bash":
                    return .init(stdout: "/bin/bash\n")
                case "command -v zsh":
                    return .init(stdout: "/bin/zsh\n")
                default:
                    break
                }
                if command.contains("/proc/stat") {
                    // 与生产一致：基础指标与进程使用两条独立命令。
                    return .init(stdout: metrics.metricOutput(
                        for: endpoint,
                        includeExtended: command.contains("os-release")
                    ))
                }
                if command.contains("ps -eo") {
                    return .init(stdout: metrics.processOutput(for: endpoint))
                }
                return DemoOps.response(command: command, endpoint: endpoint)
            },
            execCommandDelay: .milliseconds(smokeExecDelay),
            streamChunkDelay: .milliseconds(30)
        )
    }

    /// 与 `RemotePlatformDetector.posixCommand` 的分段协议保持一致。Demo 环境也必须
    /// 走完整的平台探测流程，否则探测器会把缺少 uname 标记的输出当成未知平台，
    /// 继而回退到 PowerShell，导致 Docker 等平台能力在 UI 冒烟测试中被错误禁用。
    nonisolated private static let platformProfileOutput = """
    __CONN_UNAME__
    Linux
    __CONN_RELEASE__
    6.8.0-demo
    __CONN_ARCH__
    arm64
    __CONN_SHELL__
    /bin/bash
    __CONN_END__
    """

    /// 写入演示主机与分组（含一台故障机，覆盖生产/测试/家用三组与多分组归属）。
    ///
    /// 必须一并种分组：否则服务器页的分组筛选条在 `CONN_DEMO` 截图与冒烟模式下
    /// 完全不渲染，新功能不可见。
    static func seedHosts(into store: HostStore, groups groupStore: HostGroupStore) throws {
        let prod = HostGroup(name: L("生产"), sortOrder: 0)
        let staging = HostGroup(name: L("测试"), sortOrder: 1)
        let home = HostGroup(name: L("家用"), sortOrder: 2)
        for group in [prod, staging, home] {
            try groupStore.save(group)
        }

        let hosts = [
            Host(name: "web-01", address: "10.20.0.11", username: "root",
                 groupIDs: [prod.id], tags: ["prod", "web"]),
            Host(name: "api-02", address: "10.20.0.12", username: "deploy",
                 groupIDs: [prod.id], tags: ["prod", "api"]),
            Host(name: "db-01", address: faultHostAddress, username: "root",
                 groupIDs: [prod.id], tags: ["prod", "db"]),
            Host(name: "cache-01", address: "10.20.0.21", username: "deploy",
                 groupIDs: [staging.id], tags: ["staging"]),
            // 同时属于两个分组，用来验证多分组归属。
            Host(name: "worker-01", address: "10.20.0.31", username: "root",
                 groupIDs: [staging.id, prod.id], tags: ["staging", "batch"]),
            Host(name: "nas-01", address: "192.168.1.10", username: "admin",
                 groupIDs: [home.id], tags: ["home"])
        ]
        for host in hosts {
            try store.save(host)
        }
    }
}
#endif
