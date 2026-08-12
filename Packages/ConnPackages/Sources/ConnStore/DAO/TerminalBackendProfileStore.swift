import ConnKit
import GRDB

public enum TerminalBackendProfileStoreError: Error, Sendable, Equatable {
    case profileNotFound(String)
    case identityMutation(profileID: String)
    case disabledPrimary(profileID: String)
    case scopeMismatch(
        profileID: String,
        expectedHostID: String,
        expectedProviderID: String
    )
}

/// GRDB implementation of the provider-neutral backend profile repository.
/// Provider payloads remain opaque and are never decoded in ConnStore.
public struct TerminalBackendProfileStore: TerminalBackendProfileRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func profiles(
        hostID: String,
        providerID: String?
    ) throws -> [TerminalBackendProfile] {
        try database.writer.read { db in
            let records: [TerminalBackendProfileRecord]
            if let providerID {
                records = try TerminalBackendProfileRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM terminal_backend_profile
                    WHERE host_uuid = ? AND provider_id = ?
                    ORDER BY sort_order ASC, created_at ASC, uuid ASC
                    """,
                    arguments: [hostID, providerID]
                )
            } else {
                records = try TerminalBackendProfileRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM terminal_backend_profile
                    WHERE host_uuid = ?
                    ORDER BY sort_order ASC, created_at ASC, uuid ASC
                    """,
                    arguments: [hostID]
                )
            }
            return records.map { $0.toDomain() }
        }
    }

    public func profile(id: String) throws -> TerminalBackendProfile? {
        try database.writer.read { db in
            try TerminalBackendProfileRecord.fetchOne(db, key: id)?.toDomain()
        }
    }

    public func save(_ profile: TerminalBackendProfile) throws {
        try database.writer.write { db in
            let existing = try TerminalBackendProfileRecord.fetchOne(db, key: profile.id)
            if let existing, existing.identity != profile.identity {
                throw TerminalBackendProfileStoreError.identityMutation(profileID: profile.id)
            }

            var updated = profile
            updated.updatedAt = Timestamp.now()
            updated.syncDirty = true

            if !updated.isEnabled, updated.isPrimary {
                guard existing?.isPrimary == true else {
                    throw TerminalBackendProfileStoreError.disabledPrimary(profileID: profile.id)
                }
                // Disabling the current primary is valid, but the persisted row itself can no
                // longer remain primary. A replacement is elected after this write succeeds.
                updated.isPrimary = false
            }

            if updated.isPrimary {
                try Self.clearPrimary(
                    hostID: updated.hostID,
                    providerID: updated.providerID,
                    updatedAt: updated.updatedAt,
                    in: db
                )
            }

            try TerminalBackendProfileRecord(updated).save(db)

            if existing?.isPrimary == true, !updated.isEnabled {
                try Self.electPrimaryIfNeeded(
                    hostID: updated.hostID,
                    providerID: updated.providerID,
                    updatedAt: updated.updatedAt,
                    in: db
                )
            }
        }
    }

    public func delete(id: String) throws {
        try database.writer.write { db in
            guard let existing = try TerminalBackendProfileRecord.fetchOne(db, key: id) else {
                return
            }
            try TerminalBackendProfileRecord.deleteOne(db, key: id)

            if existing.isPrimary {
                try Self.electPrimaryIfNeeded(
                    hostID: existing.hostUUID,
                    providerID: existing.providerID,
                    updatedAt: Timestamp.now(),
                    in: db
                )
            }
        }
    }

    public func setPrimary(
        id: String?,
        hostID: String,
        providerID: String
    ) throws {
        try database.writer.write { db in
            let updatedAt = Timestamp.now()
            guard let id else {
                try Self.clearPrimary(
                    hostID: hostID,
                    providerID: providerID,
                    updatedAt: updatedAt,
                    in: db
                )
                return
            }

            guard let selected = try TerminalBackendProfileRecord.fetchOne(db, key: id) else {
                throw TerminalBackendProfileStoreError.profileNotFound(id)
            }
            guard selected.hostUUID == hostID, selected.providerID == providerID else {
                throw TerminalBackendProfileStoreError.scopeMismatch(
                    profileID: id,
                    expectedHostID: hostID,
                    expectedProviderID: providerID
                )
            }
            guard selected.isEnabled else {
                throw TerminalBackendProfileStoreError.disabledPrimary(profileID: id)
            }

            try Self.clearPrimary(
                hostID: hostID,
                providerID: providerID,
                updatedAt: updatedAt,
                in: db
            )
            try db.execute(
                sql: """
                UPDATE terminal_backend_profile
                SET is_primary = 1, updated_at = ?, sync_dirty = 1
                WHERE uuid = ?
                """,
                arguments: [updatedAt, id]
            )
        }
    }

    private static func clearPrimary(
        hostID: String,
        providerID: String,
        updatedAt: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE terminal_backend_profile
            SET is_primary = 0, updated_at = ?, sync_dirty = 1
            WHERE host_uuid = ? AND provider_id = ? AND is_primary = 1
            """,
            arguments: [updatedAt, hostID, providerID]
        )
    }

    private static func electPrimaryIfNeeded(
        hostID: String,
        providerID: String,
        updatedAt: Int64,
        in db: Database
    ) throws {
        let alreadyHasPrimary = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM terminal_backend_profile
                WHERE host_uuid = ? AND provider_id = ? AND is_primary = 1
            )
            """,
            arguments: [hostID, providerID]
        ) ?? false
        guard !alreadyHasPrimary else { return }

        guard let replacementID = try String.fetchOne(
            db,
            sql: """
            SELECT uuid FROM terminal_backend_profile
            WHERE host_uuid = ? AND provider_id = ? AND is_enabled = 1
            ORDER BY sort_order ASC, created_at ASC, uuid ASC
            LIMIT 1
            """,
            arguments: [hostID, providerID]
        ) else { return }

        try db.execute(
            sql: """
            UPDATE terminal_backend_profile
            SET is_primary = 1, updated_at = ?, sync_dirty = 1
            WHERE uuid = ?
            """,
            arguments: [updatedAt, replacementID]
        )
    }
}
