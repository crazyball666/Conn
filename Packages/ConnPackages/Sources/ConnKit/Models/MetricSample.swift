import Foundation

/// 一次监控采样。
///
/// 主键为 `(hostUUID, ts)`。原始采样保留 48h，之后聚合到 `metric_hourly`
/// 保留 30 天（技术实现方案 §4.3）。
public struct MetricSample: Codable, Sendable, Equatable {
    public let hostUUID: String
    public let ts: Int64
    /// CPU 使用率 0–100。需两次 `/proc/stat` 差分得出。
    public var cpu: Double
    /// 内存使用率 0–100。
    public var mem: Double
    /// 1 分钟平均负载。
    public var load1: Double
    /// 已用磁盘字节数。
    public var diskUsed: Double
    /// 磁盘总字节数。
    public var diskTotal: Double
    /// 累计接收字节数（单调递增，速率由相邻样本差分得出）。
    public var netRx: Int64
    /// 累计发送字节数。
    public var netTx: Int64

    public init(
        hostUUID: String,
        ts: Int64 = Timestamp.now(),
        cpu: Double,
        mem: Double,
        load1: Double,
        diskUsed: Double,
        diskTotal: Double,
        netRx: Int64,
        netTx: Int64
    ) {
        self.hostUUID = hostUUID
        self.ts = ts
        self.cpu = cpu
        self.mem = mem
        self.load1 = load1
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.netRx = netRx
        self.netTx = netTx
    }

    /// 磁盘使用率 0–100。总量为 0 时返回 0，避免除零。
    public var diskPercent: Double {
        diskTotal > 0 ? diskUsed / diskTotal * 100 : 0
    }
}
