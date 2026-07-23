import ConnKit
import Foundation
import GRDB

/// `metric_sample` 表的读写入口。`ConnKit.MetricRepository` 的 GRDB 实现。
public struct MetricStore: MetricRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 写入一条样本。主键 `(host_uuid, ts)` 冲突时覆盖。
    public func record(_ sample: MetricSample) throws {
        try database.writer.write { db in
            // save = 有则更新、无则插入；ms 级 ts 实际不会撞键
            try MetricRecord(sample).save(db)
        }
    }

    /// 某主机最近一条样本。
    public func latest(hostUUID: String) throws -> MetricSample? {
        try database.writer.read { db in
            try MetricRecord
                .filter(sql: "host_uuid = ?", arguments: [hostUUID])
                .order(sql: "ts DESC")
                .fetchOne(db)?
                .toDomain()
        }
    }

    /// 某主机 `since`（含）之后的样本，按时间升序。
    public func recentSamples(hostUUID: String, since: Int64) throws -> [MetricSample] {
        try database.writer.read { db in
            try MetricRecord
                .filter(sql: "host_uuid = ? AND ts >= ?", arguments: [hostUUID, since])
                .order(sql: "ts ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    /// 清理早于 `ts` 的样本（48h TTL，App 启动时调用）。
    public func pruneSamples(olderThan ts: Int64) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM metric_sample WHERE ts < ?", arguments: [ts])
        }
    }
}
