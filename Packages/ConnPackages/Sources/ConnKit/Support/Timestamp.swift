import Foundation

/// Unix 毫秒时间戳工具。
///
/// 全库统一用 `Int64` 毫秒表示时间点（GRDB schema 中所有 `created_at` /
/// `updated_at` / `ts` 字段均为此格式），避免 `Double` 浮点误差影响
/// `metric_sample` 的主键 `(host_uuid, ts)` 唯一性。
public enum Timestamp {
    /// 当前时刻的 Unix 毫秒数。
    public static func now() -> Int64 {
        milliseconds(from: Date())
    }

    /// 把 `Date` 转为 Unix 毫秒数。
    ///
    /// 采用就近取整而非截断：`Date` 内部是 `Double` 秒，乘 1000 后常出现
    /// `...789.0000002` 这类表示误差，截断会丢 1ms。
    public static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// 把 Unix 毫秒数转回 `Date`。
    public static func date(from milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}
