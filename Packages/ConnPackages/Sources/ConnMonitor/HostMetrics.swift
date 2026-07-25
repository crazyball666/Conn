import ConnKit
import Foundation

/// 一台主机一次采集的完整结果。
///
/// CPU/内存/磁盘用可选：某项缺失（如首次采集 CPU 尚无差分、或 `/proc` 缺段）
/// 时为 nil，UI 显示「—」而不是拿 0 冒充。`sample` 是落库用的定型样本
/// （缺失项以 0 记入 `metric_sample`，仅供离线快照）。
///
/// 速率字段（net/io Rate）需相邻两次采样差分，用**服务器自身 uptime** 作时钟
/// （免受客户端时钟漂移与网络延迟影响）；首采无基线时为 nil。
public struct HostMetrics: Sendable, Equatable {
    public let hostID: String
    /// CPU 使用率 0–100。首次采集（无上次快照可差分）时为 nil。
    public let cpu: Double?
    /// CPU 逻辑核心数（`/proc/stat` 里 `cpuN` 行计数）。
    public let cpuCores: Int?
    /// 各逻辑核使用率 0–100（顺序即核序）。首采无差分基线时为 nil。
    public let cpuPerCore: [Double]?
    /// CPU 型号（`/proc/cpuinfo` model name）。
    public let cpuModel: String?
    /// 发行版友好名（`/etc/os-release` PRETTY_NAME）。
    public let osName: String?
    public let mem: Double?
    public let memTotalBytes: Double?
    public let memUsedBytes: Double?
    /// 缓冲/缓存、空闲字节（内存明细）。
    public let memBuffersCache: Double?
    public let memFree: Double?
    public let disk: Double?
    public let diskUsedBytes: Double?
    public let diskTotalBytes: Double?
    public let load1: Double?
    public let load5: Double?
    public let load15: Double?
    /// 累计收/发字节（单调递增）。
    public let netRx: Int64?
    public let netTx: Int64?
    /// 收/发速率（字节/秒）。相邻样本差分得出。
    public let netRxRate: Double?
    public let netTxRate: Double?
    /// 磁盘 IO 累计读/写字节（`/proc/diskstats` 扇区 ×512）。
    public let ioReadBytes: Int64?
    public let ioWriteBytes: Int64?
    /// 磁盘 IO 读/写速率（字节/秒）。
    public let ioReadRate: Double?
    public let ioWriteRate: Double?
    public let processes: [RemoteProcess]
    public let uptimeSeconds: Double?
    public let severity: MetricSeverity
    /// 落库样本。
    public let sample: MetricSample

    public init(
        hostID: String,
        cpu: Double?,
        cpuCores: Int? = nil,
        cpuPerCore: [Double]? = nil,
        cpuModel: String? = nil,
        osName: String? = nil,
        mem: Double?,
        memTotalBytes: Double? = nil,
        memUsedBytes: Double? = nil,
        memBuffersCache: Double? = nil,
        memFree: Double? = nil,
        disk: Double?,
        diskUsedBytes: Double? = nil,
        diskTotalBytes: Double? = nil,
        load1: Double?,
        load5: Double? = nil,
        load15: Double? = nil,
        netRx: Int64?,
        netTx: Int64?,
        netRxRate: Double? = nil,
        netTxRate: Double? = nil,
        ioReadBytes: Int64? = nil,
        ioWriteBytes: Int64? = nil,
        ioReadRate: Double? = nil,
        ioWriteRate: Double? = nil,
        processes: [RemoteProcess],
        uptimeSeconds: Double?,
        severity: MetricSeverity,
        sample: MetricSample
    ) {
        self.hostID = hostID
        self.cpu = cpu
        self.cpuCores = cpuCores
        self.cpuPerCore = cpuPerCore
        self.cpuModel = cpuModel
        self.osName = osName
        self.mem = mem
        self.memTotalBytes = memTotalBytes
        self.memUsedBytes = memUsedBytes
        self.memBuffersCache = memBuffersCache
        self.memFree = memFree
        self.disk = disk
        self.diskUsedBytes = diskUsedBytes
        self.diskTotalBytes = diskTotalBytes
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.netRx = netRx
        self.netTx = netTx
        self.netRxRate = netRxRate
        self.netTxRate = netTxRate
        self.ioReadBytes = ioReadBytes
        self.ioWriteBytes = ioWriteBytes
        self.ioReadRate = ioReadRate
        self.ioWriteRate = ioWriteRate
        self.processes = processes
        self.uptimeSeconds = uptimeSeconds
        self.severity = severity
        self.sample = sample
    }
}
