import ConnKit
import Foundation
import GRDB

/// `ssh_key` 表的读写入口。
public struct SSHKeyStore: SSHKeyRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allKeys() throws -> [SSHKey] {
        try database.writer.read { db in
            try SSHKeyRecord
                .filter(sql: "deleted_at IS NULL")
                .order(sql: "created_at DESC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func key(id: String) throws -> SSHKey? {
        try database.writer.read { db in
            try SSHKeyRecord.fetchOne(db, key: id).flatMap { $0.deletedAt == nil ? $0.toDomain() : nil }
        }
    }

    public func save(_ key: SSHKey) throws {
        var updated = key
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try SSHKeyRecord(updated).save($0) }
    }

    public func softDelete(id: String) throws {
        let now = Timestamp.now()
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE ssh_key SET deleted_at = ?, sync_dirty = 1, updated_at = ? WHERE uuid = ?",
                arguments: [now, now, id]
            )
        }
    }
}

/// `ssh_key` 表的 GRDB 记录。
struct SSHKeyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "ssh_key"

    var uuid: String
    var name: String
    var kind: String
    var publicKey: String
    var privateRef: String?
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool
    var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case uuid, name, kind
        case publicKey = "public_key"
        case privateRef = "private_ref"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
        case deletedAt = "deleted_at"
    }

    init(_ key: SSHKey) {
        uuid = key.id
        name = key.name
        kind = key.kind.rawValue
        publicKey = key.publicKey
        privateRef = key.privateRef
        createdAt = key.createdAt
        updatedAt = key.updatedAt
        syncDirty = key.syncDirty
        deletedAt = key.deletedAt
    }

    func toDomain() -> SSHKey {
        SSHKey(
            id: uuid,
            name: name,
            kind: SSHKey.Kind(rawValue: kind) ?? .ed25519,
            publicKey: publicKey,
            privateRef: privateRef,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty,
            deletedAt: deletedAt
        )
    }
}
