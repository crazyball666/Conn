import ConnKit
import Foundation
import GRDB

/// `host` 表的读写入口。
public struct HostStore: Sendable {
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

    /// 全部未删除的主机，按 `sortOrder` 再按名称排序。
    public func allHosts() throws -> [ConnKit.Host] {
        try database.writer.read { db in
            try HostRecord
                .filter(sql: "deleted_at IS NULL")
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    /// 按 id 取一台主机。已软删除的返回 nil。
    public func host(id: String) throws -> ConnKit.Host? {
        try database.writer.read { db in
            try HostRecord.fetchOne(db, key: id).flatMap { $0.deletedAt == nil ? $0.toDomain() : nil }
        }
    }

    /// 软删除（写墓碑），30 天后由清理任务物理删除。
    ///
    /// 不做物理删除是为了让 v1.1 的 iCloud 同步能把删除操作传播到其他设备；
    /// 直接 DELETE 会导致其他设备把该主机当作「本地新增」重新同步回来。
    public func softDelete(id: String) throws {
        let now = Timestamp.now()
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE host SET deleted_at = ?, sync_dirty = 1, updated_at = ? WHERE uuid = ?",
                arguments: [now, now, id]
            )
        }
    }
}
