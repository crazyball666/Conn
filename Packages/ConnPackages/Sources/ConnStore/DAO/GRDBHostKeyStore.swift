import ConnKit
import ConnSSH
import Foundation
import GRDB

/// `known_host` 表支撑的 TOFU 指纹库（`ConnSSH.HostKeyStore` 的持久化实现）。
///
/// 与内存实现同语义：首次入库、相同放行、变更阻断且不覆盖。指纹跨 App 重启
/// 留存，是防降级攻击的基础（技术方案 §4.1）。
public struct GRDBHostKeyStore: HostKeyStore {
    private let database: AppDatabase
    private let state: FailureState

    private final class FailureState: @unchecked Sendable {
        private let lock = NSLock()
        private var failedEndpoints: Set<String> = []

        func markFailed(_ endpoint: SSHEndpoint) {
            _ = lock.withLock { failedEndpoints.insert(endpoint.identifier) }
        }

        func hasFailed(_ endpoint: SSHEndpoint) -> Bool {
            lock.withLock { failedEndpoints.contains(endpoint.identifier) }
        }
    }

    public init(database: AppDatabase) {
        self.database = database
        state = FailureState()
    }

    public func knownFingerprint(for endpoint: SSHEndpoint) -> String? {
        do {
            return try database.writer.read { db in
                try KnownHostRecord
                    .filter(sql: "host_pattern = ?", arguments: [endpoint.identifier])
                    .fetchOne(db)?
                    .fingerprint
            }
        } catch {
            state.markFailed(endpoint)
            return nil
        }
    }

    public func remember(_ fingerprint: String, for endpoint: SSHEndpoint) {
        // 用 host_pattern 唯一索引做 upsert：同主机改指纹时覆盖那一行。
        do {
            try database.writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO known_host (uuid, host_pattern, key_type, fingerprint, first_seen)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(host_pattern, key_type) DO UPDATE SET fingerprint = excluded.fingerprint
                    """,
                    arguments: [UUID().uuidString, endpoint.identifier, "unknown", fingerprint, Timestamp.now()]
                )
            }
        } catch {
            state.markFailed(endpoint)
        }
    }

    public func evaluate(_ presented: String, for endpoint: SSHEndpoint) -> HostKeyVerdict {
        guard !state.hasFailed(endpoint) else { return .unavailable }
        let known = knownFingerprint(for: endpoint)
        guard !state.hasFailed(endpoint) else { return .unavailable }
        guard let known else {
            remember(presented, for: endpoint)
            return state.hasFailed(endpoint) ? .unavailable : .trustedFirstUse
        }
        return known == presented ? .matches : .mismatch(known: known)
    }
}

/// `known_host` 表的 GRDB 记录。
struct KnownHostRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "known_host"

    var uuid: String
    var hostPattern: String
    var keyType: String
    var fingerprint: String
    var firstSeen: Int64

    enum CodingKeys: String, CodingKey {
        case uuid, fingerprint
        case hostPattern = "host_pattern"
        case keyType = "key_type"
        case firstSeen = "first_seen"
    }
}
