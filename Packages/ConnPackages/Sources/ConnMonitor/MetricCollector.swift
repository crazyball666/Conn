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

    /// 各网卡差分基线：上次各网卡累计 + 服务器 uptime。
    private struct InterfaceBaseline {
        var uptime: Double
        var interfaces: [String: RawInterface]
    }

    /// 本次网络/IO 速率（字节/秒）。首采或重启时相应项为 nil。
    private struct Rates {
        var netRx: Double?
        var netTx: Double?
        var ioRead: Double?
        var ioWrite: Double?
    }

    private var previousCPU: [String: CPUJiffies] = [:]
    private var previousTimes: [String: CPUTimes] = [:]
    private var previousPerCore: [String: [CPUJiffies]] = [:]
    private var previousRate: [String: RateBaseline] = [:]
    private var previousInterfaces: [String: InterfaceBaseline] = [:]

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

        // CPU 各类占比：汇总时间片跨样本差分。
        let breakdown = cpuBreakdown(host: host, current: parsed.cpuTimes)

        // 各核利用率：逐核 jiffies 差分。
        let perCore = perCoreUsage(host: host, current: parsed.cpuPerCore)

        // 网络/IO 速率：用服务器自身 uptime 作时钟差分（免客户端时钟漂移/网络延迟）。
        let rates = updateRates(host: host, parsed: parsed)

        // 各网卡明细（含速率）。
        let interfaces = buildInterfaces(host: host, parsed: parsed)

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
            cpuBreakdown: breakdown,
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
            interfaces: interfaces,
            tcp: parsed.tcp,
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

    /// 组装各网卡明细（累计 + 速率 + IP）。速率按 uptime 差分；无基线时为 nil。
    /// 排序：物理网卡在前（按流量降序），`lo` 置末。
    private func buildInterfaces(host: ConnKit.Host, parsed: ParsedMetrics) -> [NetInterface] {
        let current = parsed.netInterfaces
        var rates: [String: (rx: Double?, tx: Double?)] = [:]
        if let uptime = parsed.uptimeSeconds, let previous = previousInterfaces[host.id] {
            let dt = uptime - previous.uptime
            for iface in current where previous.interfaces[iface.name] != nil {
                let prior = previous.interfaces[iface.name]!
                rates[iface.name] = (Self.rate(iface.rx, prior.rx, over: dt), Self.rate(iface.tx, prior.tx, over: dt))
            }
        }
        if let uptime = parsed.uptimeSeconds {
            previousInterfaces[host.id] = InterfaceBaseline(
                uptime: uptime,
                interfaces: Dictionary(current.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            )
        }
        return current
            .map { iface in
                NetInterface(
                    name: iface.name, ip: parsed.interfaceIPs[iface.name],
                    rxRate: rates[iface.name]?.rx, txRate: rates[iface.name]?.tx,
                    rxTotal: iface.rx, txTotal: iface.tx
                )
            }
            .sorted { lhs, rhs in
                if (lhs.name == "lo") != (rhs.name == "lo") { return rhs.name == "lo" }
                return (lhs.rxTotal + lhs.txTotal) > (rhs.rxTotal + rhs.txTotal)
            }
    }

    /// 汇总时间片差分求 CPU 各类占比。首采无基线时返回 nil。
    private func cpuBreakdown(host: ConnKit.Host, current: CPUTimes?) -> CPUBreakdown? {
        defer { previousTimes[host.id] = current }
        guard let current, let previous = previousTimes[host.id] else { return nil }
        return CPUBreakdown.between(previous: previous, current: current)
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
        previousTimes[hostID] = nil
        previousPerCore[hostID] = nil
        previousRate[hostID] = nil
        previousInterfaces[hostID] = nil
    }
}

/// 进程处置（PRD §5.4：Top 进程支持 kill，二次确认在 UI 层）。
public enum ProcessControl {
    /// 向进程发信号（默认 SIGTERM=15；强杀用 SIGKILL=9）。
    public static func kill(pid: Int32, signal: Int32 = 15, on session: any SSHSession) async throws -> ExecResult {
        try await session.exec("kill -\(signal) \(pid)")
    }
}
