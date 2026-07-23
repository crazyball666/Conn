import Foundation

/// `/proc/stat` 首行的 CPU 时间累计（单位 jiffies，单调递增）。
///
/// CPU 利用率无法从单次快照得出——它是「两次采样之间忙碌时间占总时间的比例」，
/// 故需保留上次快照做差分（技术实现方案 §4.3）。
public struct CPUJiffies: Sendable, Equatable {
    /// 全部时间片之和（user+nice+system+idle+iowait+irq+softirq+steal）。
    public let total: Double
    /// 空闲时间片（idle + iowait）。
    public let idle: Double

    public init(total: Double, idle: Double) {
        self.total = total
        self.idle = idle
    }
}

public enum CPUCalculator {
    /// 两次 `/proc/stat` 差分求 CPU 利用率 0–100。
    ///
    /// 总时间无增量（两次采样过近或计数回绕）时返回 nil——宁可不显示也不显示错值。
    public static func usage(previous: CPUJiffies, current: CPUJiffies) -> Double? {
        let totalDelta = current.total - previous.total
        let idleDelta = current.idle - previous.idle
        guard totalDelta > 0 else { return nil }
        let busyDelta = totalDelta - idleDelta
        return max(0, min(100, busyDelta / totalDelta * 100))
    }
}
