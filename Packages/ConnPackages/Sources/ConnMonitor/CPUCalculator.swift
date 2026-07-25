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

/// `/proc/stat` 首行各时间片累计（jiffies）。用于跨样本差分求各类占比。
public struct CPUTimes: Sendable, Equatable {
    public let user: Double
    public let nice: Double
    public let system: Double
    public let idle: Double
    public let iowait: Double
    public let irq: Double
    public let softirq: Double
    public let steal: Double

    public init(
        user: Double, nice: Double, system: Double, idle: Double,
        iowait: Double, irq: Double, softirq: Double, steal: Double
    ) {
        self.user = user
        self.nice = nice
        self.system = system
        self.idle = idle
        self.iowait = iowait
        self.irq = irq
        self.softirq = softirq
        self.steal = steal
    }

    public var total: Double { user + nice + system + idle + iowait + irq + softirq + steal }
}

/// CPU 各类时间占比（%，跨两次采样差分得出）。
///
/// 运维语义：`iowait` 高 → 磁盘/IO 瓶颈；`steal` 高 → 虚拟化宿主超卖（吵闹邻居）；
/// `system` 高 → 内核/系统调用密集；`softirq`/`irq` 高 → 中断（常见网络）压力。
public struct CPUBreakdown: Sendable, Equatable {
    public let user: Double
    public let system: Double
    public let iowait: Double
    public let nice: Double
    public let irq: Double
    public let softirq: Double
    public let steal: Double
    public let idle: Double

    public init(
        user: Double, system: Double, iowait: Double, nice: Double,
        irq: Double, softirq: Double, steal: Double, idle: Double
    ) {
        self.user = user
        self.system = system
        self.iowait = iowait
        self.nice = nice
        self.irq = irq
        self.softirq = softirq
        self.steal = steal
        self.idle = idle
    }

    /// 两次 `CPUTimes` 差分求各类占比。总时间无增量时返回 nil。
    public static func between(previous: CPUTimes, current: CPUTimes) -> CPUBreakdown? {
        let totalDelta = current.total - previous.total
        guard totalDelta > 0 else { return nil }
        func percent(_ now: Double, _ before: Double) -> Double {
            max(0, min(100, (now - before) / totalDelta * 100))
        }
        return CPUBreakdown(
            user: percent(current.user, previous.user),
            system: percent(current.system, previous.system),
            iowait: percent(current.iowait, previous.iowait),
            nice: percent(current.nice, previous.nice),
            irq: percent(current.irq, previous.irq),
            softirq: percent(current.softirq, previous.softirq),
            steal: percent(current.steal, previous.steal),
            idle: percent(current.idle, previous.idle)
        )
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
