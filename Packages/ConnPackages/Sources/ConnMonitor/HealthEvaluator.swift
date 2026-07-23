import Foundation

/// 指标严重度。领域中立——App 层再映射到 ConnUI 的 `ConnHealthStatus`
/// （设计系统不依赖领域模型）。
public enum MetricSeverity: Sendable, Equatable {
    /// 各项均在阈值内。
    case ok
    /// 有指标越过警戒线。
    case warn
    /// 有指标越过危险线。
    case crit
    /// 无任何有效读数（尚未采集或全部缺失）。
    case unknown
}

/// 由指标读数判定健康严重度。阈值与 ConnUI `ConnThreshold`（80/92）一致。
public enum HealthEvaluator {
    /// 越过此值转警戒。
    public static let warnThreshold = 80.0
    /// 越过此值转危险。
    public static let critThreshold = 92.0

    /// 取 CPU/内存/磁盘中最严重的一项。全部缺失时 `.unknown`。
    public static func severity(cpu: Double?, mem: Double?, disk: Double?) -> MetricSeverity {
        let values = [cpu, mem, disk].compactMap { $0 }
        guard !values.isEmpty else { return .unknown }
        if values.contains(where: { $0 > critThreshold }) { return .crit }
        if values.contains(where: { $0 > warnThreshold }) { return .warn }
        return .ok
    }
}
