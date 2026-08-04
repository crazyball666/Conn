import ConnKit
import Foundation
import GRDB

public enum HostStoreError: Error, Equatable {
    case unknownAuthKind(rawValue: String)
}

/// `host` 表的读写入口。`ConnKit.HostRepository` 的 GRDB 实现。
public struct HostStore: HostRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 插入或整体覆盖一台主机。
    ///
    /// 会自动刷新 `updatedAt` 并置 `syncDirty`，供 v1.1 的同步引擎消费。
    ///
    /// **先写实体记录再写成员行**——外键要求两端实体已存在。
    /// 库中不存在的 group id 会被静默丢弃（分组被删是良性竞态），
    /// 否则外键违例会打掉整个保存事务。
    public func save(_ host: ConnKit.Host) throws {
        var updated = host
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { db in
            try HostRecord(updated).save(db)
            try db.execute(
                sql: "DELETE FROM host_group_membership WHERE host_uuid = ?",
                arguments: [updated.id]
            )
            var seen = Set<String>()
            for groupID in updated.groupIDs where seen.insert(groupID).inserted {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM host_group WHERE uuid = ?)",
                    arguments: [groupID]
                ) ?? false
                guard exists else { continue }
                try db.execute(
                    sql: "INSERT INTO host_group_membership (host_uuid, group_uuid) VALUES (?, ?)",
                    arguments: [updated.id, groupID]
                )
            }
        }
    }

    /// 全部主机，按 `sortOrder` 再按名称排序。
    public func allHosts() throws -> [ConnKit.Host] {
        try database.writer.read { db in
            try HostRecord
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { try $0.toDomain(groupIDs: groupIDs(for: $0.uuid, in: db)) }
        }
    }

    /// 按 id 取一台主机。
    public func host(id: String) throws -> ConnKit.Host? {
        try database.writer.read { db in
            guard let record = try HostRecord.fetchOne(db, key: id) else { return nil }
            return try record.toDomain(groupIDs: groupIDs(for: record.uuid, in: db))
        }
    }

    /// 某主机所属分组的 id，按分组自身的排序权重返回。
    private func groupIDs(for hostID: String, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT membership.group_uuid
            FROM host_group_membership AS membership
            JOIN host_group AS grp ON grp.uuid = membership.group_uuid
            WHERE membership.host_uuid = ?
            ORDER BY grp.sort_order ASC, grp.name COLLATE NOCASE
            """,
            arguments: [hostID]
        )
    }

    /// 删除（真 DELETE，不可恢复）。
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM host WHERE uuid = ?", arguments: [id])
        }
    }
}
