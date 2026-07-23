import ConnKit
import Foundation

/// 一台主机一次采集的完整结果。
///
/// CPU/内存/磁盘用可选：某项缺失（如首次采集 CPU 尚无差分、或 `/proc` 缺段）
/// 时为 nil，UI 显示「—」而不是拿 0 冒充。`sample` 是落库用的定型样本
/// （缺失项以 0 记入 `metric_sample`，仅供离线快照）。
public struct HostMetrics: Sendable, Equatable {
    public let hostID: String
    /// CPU 使用率 0–100。首次采集（无上次快照可差分）时为 nil。
    public let cpu: Double?
    public let mem: Double?
    public let disk: Double?
    public let load1: Double?
    /// 累计收/发字节（单调递增）。
    public let netRx: Int64?
    public let netTx: Int64?
    public let processes: [RemoteProcess]
    public let uptimeSeconds: Double?
    public let severity: MetricSeverity
    /// 落库样本。
    public let sample: MetricSample

    public init(
        hostID: String,
        cpu: Double?,
        mem: Double?,
        disk: Double?,
        load1: Double?,
        netRx: Int64?,
        netTx: Int64?,
        processes: [RemoteProcess],
        uptimeSeconds: Double?,
        severity: MetricSeverity,
        sample: MetricSample
    ) {
        self.hostID = hostID
        self.cpu = cpu
        self.mem = mem
        self.disk = disk
        self.load1 = load1
        self.netRx = netRx
        self.netTx = netTx
        self.processes = processes
        self.uptimeSeconds = uptimeSeconds
        self.severity = severity
        self.sample = sample
    }
}
