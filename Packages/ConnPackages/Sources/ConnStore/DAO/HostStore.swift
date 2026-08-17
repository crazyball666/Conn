import ConnKit
import Foundation
import GRDB

public enum HostStoreError: Error, Equatable {
    case unknownAuthKind(rawValue: String)
}

/// `host` 表的读写入口。保存主机只处理主机及分组成员关系；终端 provider
/// 的内置配置由运行时注册表提供，不属于主机持久化事务。
public struct HostStore: HostRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

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

    public func allHosts() throws -> [ConnKit.Host] {
        try database.writer.read { db in
            try HostRecord
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { try $0.toDomain(groupIDs: groupIDs(for: $0.uuid, in: db)) }
        }
    }

    public func host(id: String) throws -> ConnKit.Host? {
        try database.writer.read { db in
            guard let record = try HostRecord.fetchOne(db, key: id) else { return nil }
            return try record.toDomain(groupIDs: groupIDs(for: record.uuid, in: db))
        }
    }

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

    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM host WHERE uuid = ?", arguments: [id])
        }
    }
}
