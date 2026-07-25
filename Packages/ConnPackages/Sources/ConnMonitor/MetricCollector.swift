import ConnKit
import ConnSSH
import Foundation

/// 采集器：在一条已建立的会话上跑采集脚本、解析、跨样本差分 CPU。
///
/// 用 actor 而非 struct，因为它要跨调用保留每主机上次的 CPU jiffies 快照
/// （CPU 利用率必须两次采样差分，方案 §4.3）。
public actor MetricCollector {
    /// 速率差分基线：累计计数 + 服务器 uptime（作时钟）。
    private struct RateBaseline {
        var netRx: Int64?
        var netTx: Int64?
        var ioRead: Int64?
        var ioWrite: Int64?
        var uptime: Double?
    }

    /// 本次网络/IO 速率（字节/秒）。首采或重启时相应项为 nil。
    private struct Rates {
        var netRx: Double?
        var netTx: Double?
        var ioRead: Double?
        var ioWrite: Double?
    }

    private var previousCPU: [String: CPUJiffies] = [:]
    private var previousPerCore: [String: [CPUJiffies]] = [:]
    private var previousRate: [String: RateBaseline] = [:]

    public init() {}

    /// 采一次。首次调用某主机时 CPU/速率为 nil（无可差分的上次快照），下次起有值。
    public func collect(host: ConnKit.Host, session: any SSHSession) async throws -> HostMetrics {
        let result = try await session.exec(CollectionScript.command)
        let parsed = MetricParser.parse(result.stdoutText)

        // CPU：jiffies 自归一,无需时钟。
        var cpuUsage: Double?
        if let current = parsed.cpu {
            if let previous = previousCPU[host.id] {
                cpuUsage = CPUCalculator.usage(previous: previous, current: current)
            }
            previousCPU[host.id] = current
        }

        // 各核利用率：逐核 jiffies 差分。
        let perCore = perCoreUsage(host: host, current: parsed.cpuPerCore)

        // 网络/IO 速率：用服务器自身 uptime 作时钟差分（免客户端时钟漂移/网络延迟）。
        let rates = updateRates(host: host, parsed: parsed)

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
            cpuCores: parsed.cpuCores,
            cpuPerCore: perCore,
            cpuModel: parsed.cpuModel,
            osName: parsed.osName,
            mem: parsed.memPercent,
            memTotalBytes: parsed.memTotalBytes,
            memUsedBytes: parsed.memUsedBytes,
            memBuffersCache: parsed.memBuffersCache,
            memFree: parsed.memFree,
            disk: diskPercent,
            diskUsedBytes: parsed.diskUsedBytes,
            diskTotalBytes: parsed.diskTotalBytes,
            load1: parsed.load1,
            load5: parsed.load5,
            load15: parsed.load15,
            netRx: parsed.netRxBytes,
            netTx: parsed.netTxBytes,
            netRxRate: rates.netRx,
            netTxRate: rates.netTx,
            ioReadBytes: parsed.ioReadBytes,
            ioWriteBytes: parsed.ioWriteBytes,
            ioReadRate: rates.ioRead,
            ioWriteRate: rates.ioWrite,
            processes: parsed.processes,
            uptimeSeconds: parsed.uptimeSeconds,
            severity: HealthEvaluator.severity(cpu: cpuUsage, mem: parsed.memPercent, disk: diskPercent),
            sample: sample
        )
    }

    /// 逐核差分求各核利用率 0–100。首采（无基线）或核数变化时返回 nil。
    private func perCoreUsage(host: ConnKit.Host, current: [CPUJiffies]) -> [Double]? {
        defer { previousPerCore[host.id] = current.isEmpty ? nil : current }
        guard let previous = previousPerCore[host.id], previous.count == current.count, !current.isEmpty else {
            return nil
        }
        return zip(previous, current).map { CPUCalculator.usage(previous: $0, current: $1) ?? 0 }
    }

    /// 更新差分基线并返回本次网络/IO 速率（字节/秒）。首采或重启时相应项为 nil。
    private func updateRates(host: ConnKit.Host, parsed: ParsedMetrics) -> Rates {
        guard let uptime = parsed.uptimeSeconds else { return Rates() }
        var result = Rates()
        if let prev = previousRate[host.id], let prevUptime = prev.uptime {
            let dt = uptime - prevUptime
            result = Rates(
                netRx: Self.rate(parsed.netRxBytes, prev.netRx, over: dt),
                netTx: Self.rate(parsed.netTxBytes, prev.netTx, over: dt),
                ioRead: Self.rate(parsed.ioReadBytes, prev.ioRead, over: dt),
                ioWrite: Self.rate(parsed.ioWriteBytes, prev.ioWrite, over: dt)
            )
        }
        previousRate[host.id] = RateBaseline(
            netRx: parsed.netRxBytes, netTx: parsed.netTxBytes,
            ioRead: parsed.ioReadBytes, ioWrite: parsed.ioWriteBytes,
            uptime: uptime
        )
        return result
    }

    /// 累计计数差分求速率（字节/秒）。计数缺失、时间无增量或计数回绕（重启）时返回 nil。
    private static func rate(_ current: Int64?, _ previous: Int64?, over dt: Double) -> Double? {
        guard let current, let previous, dt > 0 else { return nil }
        let delta = current - previous
        guard delta >= 0 else { return nil } // 回绕/重启：宁可不显示也不显示错值
        return Double(delta) / dt
    }

    /// 清除某主机的差分基线（断连或切主机时调用，避免拿旧基线算出跳变）。
    public func reset(hostID: String) {
        previousCPU[hostID] = nil
        previousPerCore[hostID] = nil
        previousRate[hostID] = nil
    }
}

/// 进程处置（PRD §5.4：Top 进程支持 kill，二次确认在 UI 层）。
public enum ProcessControl {
    /// 向进程发信号（默认 SIGTERM=15；强杀用 SIGKILL=9）。
    public static func kill(pid: Int32, signal: Int32 = 15, on session: any SSHSession) async throws -> ExecResult {
        try await session.exec("kill -\(signal) \(pid)")
    }
}
