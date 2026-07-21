import ConnKit
import Foundation
import GRDB

/// `host_group` 表的读写入口。
public struct HostGroupStore: HostGroupRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allGroups() throws -> [HostGroup] {
        try database.writer.read { db in
            try HostGroupRecord
                .filter(sql: "deleted_at IS NULL")
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func save(_ group: HostGroup) throws {
        var updated = group
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try HostGroupRecord(updated).save($0) }
    }

    public func softDelete(id: String) throws {
        let now = Timestamp.now()
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE host_group SET deleted_at = ?, sync_dirty = 1, updated_at = ? WHERE uuid = ?",
                arguments: [now, now, id]
            )
        }
    }
}

/// `host_group` 表的 GRDB 记录。
struct HostGroupRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "host_group"

    var uuid: String
    var name: String
    var sortOrder: Int
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool
    var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case uuid, name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
        case deletedAt = "deleted_at"
    }

    init(_ group: HostGroup) {
        uuid = group.id
        name = group.name
        sortOrder = group.sortOrder
        createdAt = group.createdAt
        updatedAt = group.updatedAt
        syncDirty = group.syncDirty
        deletedAt = group.deletedAt
    }

    func toDomain() -> HostGroup {
        HostGroup(
            id: uuid,
            name: name,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty,
            deletedAt: deletedAt
        )
    }
}
