import ConnKit
import ConnSSH
import Foundation

/// 采集器：在一条已建立的会话上跑采集脚本、解析、跨样本差分 CPU。
///
/// 用 actor 而非 struct，因为它要跨调用保留每主机上次的 CPU jiffies 快照
/// （CPU 利用率必须两次采样差分，方案 §4.3）。
public actor MetricCollector {
    private var previousCPU: [String: CPUJiffies] = [:]

    public init() {}

    /// 采一次。首次调用某主机时 CPU 为 nil（无可差分的上次快照），下次起有值。
    public func collect(host: ConnKit.Host, session: any SSHSession) async throws -> HostMetrics {
        let result = try await session.exec(CollectionScript.command)
        let parsed = MetricParser.parse(result.stdoutText)

        var cpuUsage: Double?
        if let current = parsed.cpu {
            if let previous = previousCPU[host.id] {
                cpuUsage = CPUCalculator.usage(previous: previous, current: current)
            }
            previousCPU[host.id] = current
        }

        let diskPercent = parsed.diskPercent
        let sample = MetricSample(
            hostUUID: host.id,
            cpu: cpuUsage ?? 0,
            mem: parsed.memPercent ?? 0,
            load1: parsed.load1 ?? 0,
            diskUsed: parsed.diskUsedBytes ?? 0,
            diskTotal: parsed.diskTotalBytes ?? 0,
            netRx: parsed.netRxBytes ?? 0,
            netTx: parsed.netTxBytes ?? 0
        )
        return HostMetrics(
            hostID: host.id,
            cpu: cpuUsage,
            mem: parsed.memPercent,
            disk: diskPercent,
            load1: parsed.load1,
            netRx: parsed.netRxBytes,
            netTx: parsed.netTxBytes,
            processes: parsed.processes,
            uptimeSeconds: parsed.uptimeSeconds,
            severity: HealthEvaluator.severity(cpu: cpuUsage, mem: parsed.memPercent, disk: diskPercent),
            sample: sample
        )
    }

    /// 清除某主机的 CPU 差分基线（断连或切主机时调用，避免拿旧基线算出跳变）。
    public func reset(hostID: String) {
        previousCPU[hostID] = nil
    }
}

/// 进程处置（PRD §5.4：Top 进程支持 kill，二次确认在 UI 层）。
public enum ProcessControl {
    /// 向进程发信号（默认 SIGTERM=15；强杀用 SIGKILL=9）。
    public static func kill(pid: Int32, signal: Int32 = 15, on session: any SSHSession) async throws -> ExecResult {
        try await session.exec("kill -\(signal) \(pid)")
    }
}
