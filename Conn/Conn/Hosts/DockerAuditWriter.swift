import ConnKit
import Foundation

struct DockerAuditWriter {
    let hostUUID: String
    private let repository: any RunHistoryRepository

    init(hostUUID: String, repository: any RunHistoryRepository) {
        self.hostUUID = hostUUID
        self.repository = repository
    }

    func record(_ summary: DockerAuditSummary) -> Bool {
        do {
            try repository.record(summary.historyEntry(hostUUID: hostUUID))
            return true
        } catch {
            return false
        }
    }

    func update(_ entry: RunHistoryEntry) -> Bool {
        do {
            try repository.update(entry)
            return true
        } catch {
            return false
        }
    }

    func recordPending(for operation: DockerOperation) -> RunHistoryEntry? {
        let summary = DockerAuditSummary(operation: operation.auditOperation, state: .unknown)
            .historyEntry(hostUUID: hostUUID)
        let entry = RunHistoryEntry(
            id: summary.id,
            hostUUID: summary.hostUUID,
            script: summary.script,
            exitCode: nil,
            outputHead: nil,
            state: .pending,
            ranAt: summary.ranAt
        )
        do {
            try repository.record(entry)
            return entry
        } catch {
            return nil
        }
    }
}
