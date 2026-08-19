import ConnKit
import Foundation
import GRDB

public enum SSHKeyStoreError: Error, Equatable {
    case unknownKind(rawValue: String)
}

/// `ssh_key` 表的读写入口。
public struct SSHKeyStore: SSHKeyRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allKeys() throws -> [SSHKey] {
        try database.writer.read { db in
            try SSHKeyRecord
                .order(sql: "created_at DESC")
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func key(id: String) throws -> SSHKey? {
        try database.writer.read { db in
            try SSHKeyRecord.fetchOne(db, key: id).map { try $0.toDomain() }
        }
    }

    public func save(_ key: SSHKey) throws {
        var updated = key
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try SSHKeyRecord(updated).save($0) }
    }

    /// 删除（真 DELETE）。仍引用该密钥的主机在同一事务中解除关联，但保留
    /// `auth_kind = key`，使连接明确报“缺少私钥”，并让主机表单要求用户重新
    /// 选择密钥或认证方式。这样既不会把主机误改成空密码认证，也不会因外键
    /// `RESTRICT` 导致用户永远删不掉正在使用的密钥。
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE host
                SET key_uuid = NULL, updated_at = ?, sync_dirty = 1
                WHERE key_uuid = ?
                """,
                arguments: [Timestamp.now(), id]
            )
            try db.execute(sql: "DELETE FROM ssh_key WHERE uuid = ?", arguments: [id])
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

    enum CodingKeys: String, CodingKey {
        case uuid, name, kind
        case publicKey = "public_key"
        case privateRef = "private_ref"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
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
    }

    func toDomain() throws -> SSHKey {
        guard let parsedKind = SSHKey.Kind(rawValue: kind) else {
            throw SSHKeyStoreError.unknownKind(rawValue: kind)
        }
        return SSHKey(
            id: uuid,
            name: name,
            kind: parsedKind,
            publicKey: publicKey,
            privateRef: privateRef,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }
}
