import ConnMultiplexer
import GRDB

/// GRDB adapter for provider-neutral persistent-terminal restoration bookmarks.
/// It is intentionally independent from host settings and provider configuration profiles.
public struct PersistentTerminalResumeStore: PersistentTerminalResumeRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allRecords() throws -> [PersistentTerminalResumeRecord] {
        try database.writer.write { db in
            let rows = try PersistentTerminalResumeRecordRow
                .order(sql: "last_connected_at DESC, created_at DESC")
                .fetchAll(db)
            var records: [PersistentTerminalResumeRecord] = []
            var corruptIDs: [String] = []
            for row in rows {
                do {
                    try records.append(row.toDomain())
                } catch {
                    corruptIDs.append(row.uuid)
                }
            }
            if !corruptIDs.isEmpty {
                try db.execute(
                    sql: "DELETE FROM persistent_terminal_resume_record WHERE uuid IN (\(databaseQuestionMarks(corruptIDs.count)))",
                    arguments: StatementArguments(corruptIDs)
                )
            }
            return records
        }
    }

    public func save(_ record: PersistentTerminalResumeRecord) throws {
        let row = try PersistentTerminalResumeRecordRow(record)
        try database.writer.write { db in
            // One local resume entry per host/provider/configuration/workspace. Reopening
            // an already-bookmarked workspace transfers the bookmark to the latest tab.
            try db.execute(
                sql: """
                DELETE FROM persistent_terminal_resume_record
                WHERE (host_uuid = ? AND provider_id = ?
                    AND provider_configuration_key = ? AND workspace_id = ?)
                   OR uuid = ?
                """,
                arguments: [
                    row.hostUUID,
                    row.providerID,
                    row.providerConfigurationKey,
                    row.workspaceID,
                    row.uuid
                ]
            )
            try row.insert(db)
        }
    }

    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM persistent_terminal_resume_record WHERE uuid = ?",
                arguments: [id]
            )
        }
    }

    public func delete(hostID: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM persistent_terminal_resume_record WHERE host_uuid = ?",
                arguments: [hostID]
            )
        }
    }
}

private func databaseQuestionMarks(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
