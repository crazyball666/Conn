import ConnKit
import Foundation
import GRDB

/// `run_history` 表的 GRDB 记录。
struct RunHistoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "run_history"

    var uuid: String
    var hostUUID: String
    var command: String
    var exitCode: Int32?
    var outputHead: String?
    var ranAt: Int64

    enum CodingKeys: String, CodingKey {
        case uuid, command
        case hostUUID = "host_uuid"
        case exitCode = "exit_code"
        case outputHead = "output_head"
        case ranAt = "ran_at"
    }
}

extension RunHistoryRecord {
    init(_ entry: RunHistoryEntry) {
        uuid = entry.id
        hostUUID = entry.hostUUID
        command = entry.command
        exitCode = entry.exitCode
        outputHead = entry.outputHead
        ranAt = entry.ranAt
    }

    func toDomain() -> RunHistoryEntry {
        RunHistoryEntry(
            id: uuid,
            hostUUID: hostUUID,
            command: command,
            exitCode: exitCode,
            outputHead: outputHead,
            ranAt: ranAt
        )
    }
}
