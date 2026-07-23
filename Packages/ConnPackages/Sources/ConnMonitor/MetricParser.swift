import Foundation

/// 采集脚本原始输出解析后的中间结果。
///
/// 各字段可选：某段在目标系统上缺失（如无 `/proc/net/dev`）时留 nil，
/// 上层据此决定是否显示，而不是拿 0 冒充真实读数。CPU 特殊——它需两次采样
/// 差分，故此处只留 jiffies 快照，利用率由 `MetricCollector` 跨样本算出。
public struct ParsedMetrics: Sendable, Equatable {
    public var cpu: CPUJiffies?
    public var memPercent: Double?
    public var load1: Double?
    public var diskUsedBytes: Double?
    public var diskTotalBytes: Double?
    public var netRxBytes: Int64?
    public var netTxBytes: Int64?
    public var uptimeSeconds: Double?
    public var processes: [RemoteProcess]

    public init(
        cpu: CPUJiffies? = nil,
        memPercent: Double? = nil,
        load1: Double? = nil,
        diskUsedBytes: Double? = nil,
        diskTotalBytes: Double? = nil,
        netRxBytes: Int64? = nil,
        netTxBytes: Int64? = nil,
        uptimeSeconds: Double? = nil,
        processes: [RemoteProcess] = []
    ) {
        self.cpu = cpu
        self.memPercent = memPercent
        self.load1 = load1
        self.diskUsedBytes = diskUsedBytes
        self.diskTotalBytes = diskTotalBytes
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.uptimeSeconds = uptimeSeconds
        self.processes = processes
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
        let disk = ProcParsers.parseDisk(section(CollectionScript.Sentinel.disk))
        let net = ProcParsers.parseNet(section(CollectionScript.Sentinel.net))
        return ParsedMetrics(
            cpu: ProcParsers.parseStat(section(CollectionScript.Sentinel.stat)),
            memPercent: ProcParsers.parseMemPercent(section(CollectionScript.Sentinel.mem)),
            load1: ProcParsers.parseLoad1(section(CollectionScript.Sentinel.load)),
            diskUsedBytes: disk?.used,
            diskTotalBytes: disk?.total,
            netRxBytes: net?.rx,
            netTxBytes: net?.tx,
            uptimeSeconds: ProcParsers.parseUptime(section(CollectionScript.Sentinel.uptime)),
            processes: ProcessParser.parse(
                psSection: section(CollectionScript.Sentinel.ps),
                topSection: section(CollectionScript.Sentinel.top)
            )
        )
    }

    /// 按 sentinel 把输出切成各段。返回 sentinel → 该段文本（不含 sentinel 行）。
    static func splitSections(_ output: String) -> [String: String] {
        let known: Set<String> = [
            CollectionScript.Sentinel.stat, CollectionScript.Sentinel.mem,
            CollectionScript.Sentinel.load, CollectionScript.Sentinel.disk,
            CollectionScript.Sentinel.net, CollectionScript.Sentinel.uptime,
            CollectionScript.Sentinel.ps, CollectionScript.Sentinel.top,
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
