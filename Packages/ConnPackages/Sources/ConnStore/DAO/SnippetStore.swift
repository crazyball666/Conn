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
        let folders = normalizedFolders(updated.folders)
        updated.folders = folders
        try database.writer.write { db in
            try SnippetRecord(updated).save(db)
            try db.execute(
                sql: "DELETE FROM snippet_folder_membership WHERE snippet_uuid = ?",
                arguments: [updated.id]
            )
            for folder in folders {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO snippet_folder (name, sort_order)
                    VALUES (?, COALESCE((SELECT MAX(sort_order) + 1 FROM snippet_folder), 0))
                    """,
                    arguments: [folder]
                )
                try db.execute(
                    sql: """
                    INSERT INTO snippet_folder_membership (snippet_uuid, folder_name)
                    VALUES (?, ?)
                    """,
                    arguments: [updated.id, folder]
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
                try record.toDomain(folders: folders(for: record.uuid, in: db))
            }
        }
    }

    public func snippet(id: String) throws -> Snippet? {
        try database.writer.read { db in
            guard let record = try SnippetRecord.fetchOne(db, key: id) else { return nil }
            return try record.toDomain(folders: folders(for: record.uuid, in: db))
        }
    }

    /// 删除（真 DELETE，不可恢复）。
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM snippet WHERE uuid = ?", arguments: [id])
        }
    }

    public func count() throws -> Int {
        try database.writer.read { db in
            try SnippetRecord.fetchCount(db)
        }
    }

    /// 全部分组按用户保存的顺序返回。
    public func allFolders() throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM snippet_folder ORDER BY sort_order ASC, name COLLATE NOCASE"
            )
        }
    }

    public func saveFolder(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try database.writer.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO snippet_folder (name, sort_order)
                VALUES (?, COALESCE((SELECT MAX(sort_order) + 1 FROM snippet_folder), 0))
                """,
                arguments: [trimmed]
            )
        }
    }

    public func deleteFolder(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Timestamp.now()
        try database.writer.write { db in
            let affectedIDs = try String.fetchAll(
                db,
                sql: "SELECT snippet_uuid FROM snippet_folder_membership WHERE folder_name = ?",
                arguments: [trimmed]
            )
            try db.execute(
                sql: "DELETE FROM snippet_folder WHERE name = ?",
                arguments: [trimmed]
            )
            for id in affectedIDs {
                let remainingFolder = try String.fetchOne(
                    db,
                    sql: """
                    SELECT membership.folder_name
                    FROM snippet_folder_membership AS membership
                    JOIN snippet_folder AS folder ON folder.name = membership.folder_name
                    WHERE membership.snippet_uuid = ?
                    ORDER BY folder.sort_order ASC, folder.name COLLATE NOCASE
                    LIMIT 1
                    """,
                    arguments: [id]
                )
                try db.execute(
                    sql: """
                    UPDATE snippet
                    SET folder = ?, updated_at = ?, sync_dirty = 1
                    WHERE uuid = ?
                    """,
                    arguments: [remainingFolder, now, id]
                )
            }
        }
    }

    private func folders(for snippetID: String, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT membership.folder_name
            FROM snippet_folder_membership AS membership
            JOIN snippet_folder AS folder ON folder.name = membership.folder_name
            WHERE membership.snippet_uuid = ?
            ORDER BY folder.sort_order ASC, folder.name COLLATE NOCASE
            """,
            arguments: [snippetID]
        )
    }

    private func normalizedFolders(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}
