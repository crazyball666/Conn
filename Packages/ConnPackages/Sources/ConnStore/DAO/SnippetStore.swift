import ConnKit
import Foundation
import GRDB

/// `snippet` 表的读写入口。`ConnKit.SnippetRepository` 的 GRDB 实现。
public struct SnippetStore: SnippetRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 插入或整体覆盖。刷新 `updatedAt` 并置 `syncDirty`（供 v1.1 同步）。
    public func save(_ snippet: Snippet) throws {
        var updated = snippet
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try SnippetRecord(updated).save($0) }
    }

    /// 全部未删除片段：置顶优先，再按排序权重与标题。
    public func allSnippets() throws -> [Snippet] {
        try database.writer.read { db in
            try SnippetRecord
                .filter(sql: "deleted_at IS NULL")
                .order(sql: "pinned DESC, sort_order ASC, title ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func snippet(id: String) throws -> Snippet? {
        try database.writer.read { db in
            try SnippetRecord.fetchOne(db, key: id).flatMap { $0.deletedAt == nil ? $0.toDomain() : nil }
        }
    }

    public func softDelete(id: String) throws {
        let now = Timestamp.now()
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE snippet SET deleted_at = ?, sync_dirty = 1, updated_at = ? WHERE uuid = ?",
                arguments: [now, now, id]
            )
        }
    }

    public func count() throws -> Int {
        try database.writer.read { db in
            try SnippetRecord.filter(sql: "deleted_at IS NULL").fetchCount(db)
        }
    }
}
