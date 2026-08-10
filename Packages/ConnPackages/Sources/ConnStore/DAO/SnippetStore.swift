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
    ///
    /// **先写实体记录再写成员行**——外键要求两端实体已存在。
    /// 库中不存在的 group id 会被静默丢弃（分组被删是良性竞态），
    /// 否则外键违例会打掉整个保存事务。
    public func save(_ snippet: Snippet) throws {
        var updated = snippet
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { db in
            try SnippetRecord(updated).save(db)
            try db.execute(
                sql: "DELETE FROM snippet_group_membership WHERE snippet_uuid = ?",
                arguments: [updated.id]
            )
            var seen = Set<String>()
            for groupID in updated.groupIDs where seen.insert(groupID).inserted {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM snippet_group WHERE uuid = ?)",
                    arguments: [groupID]
                ) ?? false
                guard exists else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO snippet_group_membership (snippet_uuid, group_uuid)
                    VALUES (?, ?)
                    """,
                    arguments: [updated.id, groupID]
                )
            }
        }
    }

    /// 全部片段：按稳定排序权重与标题。
    public func allSnippets() throws -> [Snippet] {
        try database.writer.read { db in
            let records = try SnippetRecord
                .order(sql: "sort_order ASC, title ASC")
                .fetchAll(db)
            return try records.map { record in
                try record.toDomain(groupIDs: groupIDs(for: record.uuid, in: db))
            }
        }
    }

    public func snippet(id: String) throws -> Snippet? {
        try database.writer.read { db in
            guard let record = try SnippetRecord.fetchOne(db, key: id) else { return nil }
            return try record.toDomain(groupIDs: groupIDs(for: record.uuid, in: db))
        }
    }

    public func snippet(builtinKey: String) throws -> Snippet? {
        try database.writer.read { db in
            guard let record = try SnippetRecord
                .filter(Column("builtin_key") == builtinKey)
                .fetchOne(db)
            else { return nil }
            return try record.toDomain(groupIDs: groupIDs(for: record.uuid, in: db))
        }
    }

    /// 删除（真 DELETE，不可恢复）。内置片段先写 suppression，后续目录升级不会复活；
    /// 成员行由外键级联清理。
    public func delete(id: String) throws {
        try database.writer.write { db in
            if let builtinKey = try String.fetchOne(
                db,
                sql: "SELECT builtin_key FROM snippet WHERE uuid = ?",
                arguments: [id]
            ) {
                try Self.suppressBuiltin(builtinKey, in: db)
            }
            try db.execute(sql: "DELETE FROM snippet WHERE uuid = ?", arguments: [id])
        }
    }

    public func isBuiltinSuppressed(_ builtinKey: String) throws -> Bool {
        try database.writer.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM builtin_snippet_suppression WHERE builtin_key = ?
                )
                """,
                arguments: [builtinKey]
            ) ?? false
        }
    }

    public func suppressBuiltin(_ builtinKey: String) throws {
        try database.writer.write { db in
            try Self.suppressBuiltin(builtinKey, in: db)
        }
    }

    public func builtinCatalogVersion() throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT catalog_version FROM builtin_snippet_catalog_state WHERE singleton = 1
                """
            ) ?? 0
        }
    }

    public func setBuiltinCatalogVersion(_ version: Int) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO builtin_snippet_catalog_state (singleton, catalog_version)
                VALUES (1, ?)
                ON CONFLICT(singleton) DO UPDATE SET catalog_version = excluded.catalog_version
                """,
                arguments: [version]
            )
        }
    }

    public func count() throws -> Int {
        try database.writer.read { db in
            try SnippetRecord.fetchCount(db)
        }
    }

    /// 某片段所属分组的 id，按分组自身的排序权重返回。
    private func groupIDs(for snippetID: String, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT membership.group_uuid
            FROM snippet_group_membership AS membership
            JOIN snippet_group AS grp ON grp.uuid = membership.group_uuid
            WHERE membership.snippet_uuid = ?
            ORDER BY grp.sort_order ASC, grp.name COLLATE NOCASE
            """,
            arguments: [snippetID]
        )
    }

    private static func suppressBuiltin(_ builtinKey: String, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO builtin_snippet_suppression (builtin_key, suppressed_at)
            VALUES (?, ?)
            """,
            arguments: [builtinKey, Timestamp.now()]
        )
    }
}
