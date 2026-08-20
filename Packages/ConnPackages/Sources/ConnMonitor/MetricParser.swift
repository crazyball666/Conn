import ConnKit
import Foundation

/// 采集脚本原始输出解析后的中间结果。
///
/// 各字段可选：某段在目标系统上缺失（如无 `/proc/net/dev`）时留 nil，
/// 上层据此决定是否显示，而不是拿 0 冒充真实读数。CPU 特殊——它需两次采样
/// 差分，故此处只留 jiffies 快照，利用率由 `MetricCollector` 跨样本算出。
public struct ParsedMetrics: Sendable, Equatable {
    public var cpu: CPUJiffies?
    public var cpuTimes: CPUTimes?
    /// 单次采样即可得到的 CPU 使用率；Darwin `top` 使用，Linux 保持 nil 并继续做差分。
    public var cpuInstantPercent: Double?
    /// 单次采样的 CPU 分类占比；Darwin `top` 使用。
    public var cpuBreakdownInstant: CPUBreakdown?
    public var cpuPerCore: [CPUJiffies]
    public var cpuCores: Int?
    public var cpuModel: String?
    public var osName: String?
    public var memPercent: Double?
    public var memTotalBytes: Double?
    public var memUsedBytes: Double?
    public var memBuffersCache: Double?
    public var memFree: Double?
    public var swapTotalBytes: Double?
    public var swapUsedBytes: Double?
    public var load1: Double?
    public var load5: Double?
    public var load15: Double?
    public var diskUsedBytes: Double?
    public var diskTotalBytes: Double?
    public var netRxBytes: Int64?
    public var netTxBytes: Int64?
    /// 汇总网络计数所属的接口；接口切换时用于丢弃跨接口速率差分。
    public var netCounterIdentity: String?
    public var netInterfaces: [RawInterface]
    public var interfaceIPs: [String: String]
    public var tcp: TCPStats?
    public var ioReadBytes: Int64?
    public var ioWriteBytes: Int64?
    public var uptimeSeconds: Double?
    /// 本次指标采集的能力状态；字段缺失时不再静默伪装成完整成功。
    public var capabilityState: CapabilityState

    public init(
        cpu: CPUJiffies? = nil,
        cpuTimes: CPUTimes? = nil,
        cpuInstantPercent: Double? = nil,
        cpuBreakdownInstant: CPUBreakdown? = nil,
        cpuPerCore: [CPUJiffies] = [],
        cpuCores: Int? = nil,
        cpuModel: String? = nil,
        osName: String? = nil,
        memPercent: Double? = nil,
        memTotalBytes: Double? = nil,
        memUsedBytes: Double? = nil,
        memBuffersCache: Double? = nil,
        memFree: Double? = nil,
        swapTotalBytes: Double? = nil,
        swapUsedBytes: Double? = nil,
        load1: Double? = nil,
        load5: Double? = nil,
        load15: Double? = nil,
        diskUsedBytes: Double? = nil,
        diskTotalBytes: Double? = nil,
        netRxBytes: Int64? = nil,
        netTxBytes: Int64? = nil,
        netCounterIdentity: String? = nil,
        netInterfaces: [RawInterface] = [],
        interfaceIPs: [String: String] = [:],
        tcp: TCPStats? = nil,
        ioReadBytes: Int64? = nil,
        ioWriteBytes: Int64? = nil,
        uptimeSeconds: Double? = nil,
        capabilityState: CapabilityState = .supported
    ) {
        self.cpu = cpu
        self.cpuTimes = cpuTimes
        self.cpuInstantPercent = cpuInstantPercent
        self.cpuBreakdownInstant = cpuBreakdownInstant
        self.cpuPerCore = cpuPerCore
        self.cpuCores = cpuCores
        self.cpuModel = cpuModel
        self.osName = osName
        self.memPercent = memPercent
        self.memTotalBytes = memTotalBytes
        self.memUsedBytes = memUsedBytes
        self.memBuffersCache = memBuffersCache
        self.memFree = memFree
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.diskUsedBytes = diskUsedBytes
        self.diskTotalBytes = diskTotalBytes
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.netCounterIdentity = netCounterIdentity
        self.netInterfaces = netInterfaces
        self.interfaceIPs = interfaceIPs
        self.tcp = tcp
        self.ioReadBytes = ioReadBytes
        self.ioWriteBytes = ioWriteBytes
        self.uptimeSeconds = uptimeSeconds
        self.capabilityState = capabilityState
    }

    /// 磁盘使用率 0–100。总量缺失或为 0 时返回 nil。
    public var diskPercent: Double? {
        guard let used = diskUsedBytes, let total = diskTotalBytes, total > 0 else { return nil }
        return used / total * 100
    }
}

/// 采集输出解析器。纯函数、无副作用——host 可测的核心（方案 §4.3 验收项）。
public enum MetricParser {
    /// 解析采集脚本的完整 stdout。
    public static func parse(_ output: String) -> ParsedMetrics {
        let sections = splitSections(output)
        func section(_ key: String) -> String { sections[key] ?? "" }
        let statSection = section(CollectionScript.Sentinel.stat)
        let memSection = section(CollectionScript.Sentinel.mem)
        let disk = ProcParsers.parseDisk(section(CollectionScript.Sentinel.disk))
        let net = ProcParsers.parseNet(section(CollectionScript.Sentinel.net))
        let mem = ProcParsers.parseMemInfo(memSection)
        let memDetail = ProcParsers.parseMemBreakdown(memSection)
        let io = ProcParsers.parseDiskstats(section(CollectionScript.Sentinel.io))
        let load = ProcParsers.parseLoadAvg(section(CollectionScript.Sentinel.load))
        return ParsedMetrics(
            cpu: ProcParsers.parseStat(statSection),
            cpuTimes: ProcParsers.parseStatTimes(statSection),
            cpuPerCore: ProcParsers.parsePerCore(statSection),
            cpuCores: ProcParsers.parseCoreCount(statSection),
            cpuModel: ProcParsers.parseCPUModel(section(CollectionScript.Sentinel.cpuinfo)),
            osName: ProcParsers.parseOSName(section(CollectionScript.Sentinel.os)),
            memPercent: ProcParsers.parseMemPercent(memSection),
            memTotalBytes: mem?.totalBytes,
            memUsedBytes: mem?.usedBytes,
            memBuffersCache: memDetail?.buffersCache,
            memFree: memDetail?.free,
            swapTotalBytes: memDetail?.swapTotal,
            swapUsedBytes: memDetail?.swapUsed,
            load1: load?.one,
            load5: load?.five,
            load15: load?.fifteen,
            diskUsedBytes: disk?.used,
            diskTotalBytes: disk?.total,
            netRxBytes: net?.rx,
            netTxBytes: net?.tx,
            netInterfaces: ProcParsers.parseNetInterfaces(section(CollectionScript.Sentinel.net)),
            interfaceIPs: ProcParsers.parseIPs(section(CollectionScript.Sentinel.ipaddr)),
            tcp: ProcParsers.parseTCPStats(section(CollectionScript.Sentinel.snmp)),
            ioReadBytes: io?.read,
            ioWriteBytes: io?.write,
            uptimeSeconds: ProcParsers.parseUptime(section(CollectionScript.Sentinel.uptime))
        )
    }

    /// 按 sentinel 把输出切成各段。返回 sentinel → 该段文本（不含 sentinel 行）。
    static func splitSections(_ output: String) -> [String: String] {
        let known: Set<String> = [
            CollectionScript.Sentinel.stat, CollectionScript.Sentinel.mem,
            CollectionScript.Sentinel.load, CollectionScript.Sentinel.disk,
            CollectionScript.Sentinel.net, CollectionScript.Sentinel.snmp,
            CollectionScript.Sentinel.ipaddr, CollectionScript.Sentinel.io,
            CollectionScript.Sentinel.uptime,
            CollectionScript.Sentinel.os, CollectionScript.Sentinel.cpuinfo,
            CollectionScript.Sentinel.end
        ]
        var result: [String: String] = [:]
        var current: String?
        var buffer: [Substring] = []
        func flush() {
            if let current { result[current] = buffer.joined(separator: "\n") }
            buffer.removeAll(keepingCapacity: true)
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if known.contains(trimmed) {
                flush()
                current = trimmed
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }
}
