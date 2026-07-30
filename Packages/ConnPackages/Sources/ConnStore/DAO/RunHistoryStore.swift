import ConnKit
import Foundation
import GRDB

/// `run_history` 表的读写入口。`ConnKit.RunHistoryRepository` 的 GRDB 实现。
public struct RunHistoryStore: RunHistoryRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func record(_ entry: RunHistoryEntry) throws {
        try database.writer.write { try RunHistoryRecord(entry).insert($0) }
    }

    public func update(_ entry: RunHistoryEntry) throws {
        try database.writer.write { try RunHistoryRecord(entry).update($0) }
    }

    public func recoverPending() throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE run_history SET state = ?, exit_code = NULL WHERE state = ?",
                arguments: [RunHistoryState.unknown.rawValue, RunHistoryState.pending.rawValue]
            )
        }
    }

    public func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry] {
        try database.writer.read { db in
            let request: QueryInterfaceRequest<RunHistoryRecord>
            if let hostUUID {
                request = RunHistoryRecord.filter(sql: "host_uuid = ?", arguments: [hostUUID])
            } else {
                request = RunHistoryRecord.all()
            }
            return try request
                .order(sql: "ran_at DESC")
                .limit(limit)
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }
}
