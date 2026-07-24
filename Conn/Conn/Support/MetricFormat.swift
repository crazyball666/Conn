import Foundation

/// 指标展示格式化——首页健康卡与单机详情共用，保证口径一致。
///
/// 缺失值一律返回「—」（不拿 0 冒充真实读数）。字节用二进制单位（KiB/MiB/GiB）。
enum MetricFormat {
    /// 字节（Double）。
    static func bytes(_ value: Double?) -> String {
        value.map(byteString) ?? "—"
    }

    /// 字节（Int64 累计计数）。
    static func bytes(_ value: Int64?) -> String {
        value.map { byteString(Double($0)) } ?? "—"
    }

    /// 速率：字节/秒 → 「x/s」。
    static func rate(_ bytesPerSecond: Double?) -> String {
        bytesPerSecond.map { byteString($0) + "/s" } ?? "—"
    }

    /// 「已用 / 总量」；任一缺失显示「—」。
    static func pair(used: Double?, total: Double?) -> String {
        guard let used, let total, total > 0 else { return "—" }
        return "\(byteString(used)) / \(byteString(total))"
    }

    /// 「速率 · 总量」，供卡片紧凑单元。
    static func rateAndTotal(rate rateValue: Double?, total: Int64?) -> String {
        "\(rate(rateValue)) · \(bytes(total))"
    }

    /// 1 分钟负载，两位小数。
    static func load(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "—"
    }

    /// 核心数「N 核」。
    static func cores(_ count: Int?) -> String {
        count.map { String(format: L("%d 核"), $0) } ?? "—"
    }

    /// 运行时长：「N 天 N 小时」，不足一天用「N 小时」。
    static func uptime(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        return days > 0
            ? String(format: L("%d 天 %d 小时"), days, hours)
            : String(format: L("%d 小时"), hours)
    }

    private static func byteString(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }
}
