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

    /// 删除（真 DELETE）。成员行由 `host_group_membership` 的外键级联清理。
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM host_group WHERE uuid = ?", arguments: [id])
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

    enum CodingKeys: String, CodingKey {
        case uuid, name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
    }

    init(_ group: HostGroup) {
        uuid = group.id
        name = group.name
        sortOrder = group.sortOrder
        createdAt = group.createdAt
        updatedAt = group.updatedAt
        syncDirty = group.syncDirty
    }

    func toDomain() -> HostGroup {
        HostGroup(
            id: uuid,
            name: name,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }
}
