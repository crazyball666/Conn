import Foundation

/// 指标展示格式化——首页健康卡与单机详情共用，保证口径一致。
///
/// 缺失值一律返回「—」（不拿 0 冒充真实读数）。字节统一使用 B/K/M/G 等紧凑缩写。
enum MetricFormat {
    /// 字节（Double）。
    static func bytes(_ value: Double?) -> String {
        guard let value else { return "—" }
        return byteString(value)
    }

    /// 字节（Int64 累计计数）。
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return byteString(Double(value))
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

    /// 紧凑字节：单字母单位、最多 1 位小数（卡片密排用）。「455 B / 2.7 K / 7.7 G」。
    static func compactBytes(_ bytes: Double?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = bytes
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(value)) B" }
        let text = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(text) \(units[index])"
    }

    static func compactBytes(_ bytes: Int64?) -> String {
        compactBytes(bytes.map { Double($0) })
    }

    /// 紧凑运行时长：「15 天」/「20 时」/「45 分」（卡片头部用）。
    static func compactUptime(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return String(format: L("%d 天"), days) }
        if hours > 0 { return String(format: L("%d 时"), hours) }
        return String(format: L("%d 分"), minutes)
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

    /// 时长（秒）→ 人类可读，随量级自适应精度：
    /// 「2 天 3 小时」/「5 小时 12 分」/「8 分 20 秒」/「45 秒」。供进程运行时长等。
    static func duration(_ seconds: Int64?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if days > 0 { return String(format: L("%d 天 %d 小时"), days, hours) }
        if hours > 0 { return String(format: L("%d 小时 %d 分"), hours, minutes) }
        if minutes > 0 { return String(format: L("%d 分 %d 秒"), minutes, secs) }
        return String(format: L("%d 秒"), secs)
    }

    private static func byteString(_ bytes: Double) -> String {
        compactBytes(max(0, bytes))
    }
}
