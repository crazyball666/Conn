import ConnKit
import Foundation
import GRDB

/// `run_history` 表的 GRDB 记录。
struct RunHistoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "run_history"

    var uuid: String
    var hostUUID: String
    var script: String
    var interpreter: ShellInterpreter
    var exitCode: Int32?
    var outputHead: String?
    var state: RunHistoryState
    var ranAt: Int64

    enum CodingKeys: String, CodingKey {
        case uuid, script, interpreter
        case hostUUID = "host_uuid"
        case exitCode = "exit_code"
        case outputHead = "output_head"
        case state
        case ranAt = "ran_at"
    }
}

extension RunHistoryRecord {
    init(_ entry: RunHistoryEntry) {
        uuid = entry.id
        hostUUID = entry.hostUUID
        script = entry.script
        interpreter = entry.interpreter
        exitCode = entry.exitCode
        outputHead = entry.outputHead
        state = entry.state
        ranAt = entry.ranAt
    }

    func toDomain() -> RunHistoryEntry {
        RunHistoryEntry(
            id: uuid,
            hostUUID: hostUUID,
            script: script,
            interpreter: interpreter,
            exitCode: exitCode,
            outputHead: outputHead,
            state: state,
            ranAt: ranAt
        )
    }
}
