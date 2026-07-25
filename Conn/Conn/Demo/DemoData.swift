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
        MockSSHTransport.Behavior(
            dynamicResponder: { command, endpoint in
                if command.contains("/proc/stat") {
                    // 与生产一致：按命令实际取的段回数据（详情段看 os-release、进程段看 ps）。
                    return .init(stdout: metrics.metricOutput(
                        for: endpoint,
                        includeExtended: command.contains("os-release"),
                        includeProcesses: command.contains("ps -eo")
                    ))
                }
                return DemoOps.response(command: command, endpoint: endpoint)
            },
            streamChunkDelay: .milliseconds(30)
        )
    }

    /// 写入演示主机（含一台故障机、多种标签、覆盖 prod/staging/home）。
    static func seedHosts(into store: HostStore) throws {
        let hosts = [
            Host(name: "web-01", address: "10.20.0.11", username: "root", tags: ["prod", "web"],
                 note: "主站 Nginx 入口"),
            Host(name: "api-02", address: "10.20.0.12", username: "deploy", tags: ["prod", "api"]),
            Host(name: "db-master", address: faultHostAddress, username: "root", tags: ["prod", "db"],
                 note: "生产主库，勿直接重启"),
            Host(name: "cache-01", address: "10.20.0.21", username: "deploy", tags: ["staging"]),
            Host(name: "worker-1", address: "10.20.0.31", username: "root", tags: ["staging", "batch"]),
            Host(name: "home-nas", address: "192.168.1.10", username: "admin", tags: ["home"])
        ]
        for host in hosts {
            try store.save(host)
        }
    }
}
#endif
