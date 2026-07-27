import ConnKit
import Foundation
import GRDB

/// `host` 表的读写入口。`ConnKit.HostRepository` 的 GRDB 实现。
public struct HostStore: HostRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 插入或整体覆盖一台主机。
    ///
    /// 会自动刷新 `updatedAt` 并置 `syncDirty`，供 v1.1 的同步引擎消费。
    public func save(_ host: ConnKit.Host) throws {
        var updated = host
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try HostRecord(updated).save($0) }
    }

    /// 全部主机，按 `sortOrder` 再按名称排序。
    public func allHosts() throws -> [ConnKit.Host] {
        try database.writer.read { db in
            try HostRecord
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    /// 按 id 取一台主机。
    public func host(id: String) throws -> ConnKit.Host? {
        try database.writer.read { db in
            try HostRecord.fetchOne(db, key: id).map { $0.toDomain() }
        }
    }

    /// 删除（真 DELETE，不可恢复）。
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM host WHERE uuid = ?", arguments: [id])
        }
    }
}
