import ConnKit
import Foundation
import GRDB

/// `snippet_group` 表的读写入口。与 `HostGroupStore` 同构。
public struct SnippetGroupStore: SnippetGroupRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allGroups() throws -> [SnippetGroup] {
        try database.writer.read { db in
            try SnippetGroupRecord
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func save(_ group: SnippetGroup) throws {
        var updated = group
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try SnippetGroupRecord(updated).save($0) }
    }

    /// 删除（真 DELETE）。成员行由 `snippet_group_membership` 的外键级联清理，
    /// 此处无需手动删。
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM snippet_group WHERE uuid = ?", arguments: [id])
        }
    }
}

/// `snippet_group` 表的 GRDB 记录。
struct SnippetGroupRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "snippet_group"

    var uuid: String
    var name: String
    var sortOrder: Int
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool
    var builtinKey: String?

    enum CodingKeys: String, CodingKey {
        case uuid, name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
        case builtinKey = "builtin_key"
    }

    init(_ group: SnippetGroup) {
        uuid = group.id
        name = group.name
        sortOrder = group.sortOrder
        createdAt = group.createdAt
        updatedAt = group.updatedAt
        syncDirty = group.syncDirty
        builtinKey = group.builtinKey
    }

    func toDomain() -> SnippetGroup {
        SnippetGroup(
            id: uuid,
            name: name,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty,
            builtinKey: builtinKey
        )
    }
}
