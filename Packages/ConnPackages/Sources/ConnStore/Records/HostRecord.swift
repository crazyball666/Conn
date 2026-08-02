import ConnKit
import Foundation
import GRDB

/// `host` 表的 GRDB 记录。
///
/// 与领域模型 `ConnKit.Host` 分离：领域层不应知道列名与 JSON 编码细节。
struct HostRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "host"

    var uuid: String
    var name: String
    var address: String
    var port: Int
    var username: String
    var authKind: String
    var credentialRef: String?
    var keyUUID: String?
    var jumpChain: String // JSON 数组
    var tags: String // JSON 数组
    var icon: String?
    var color: String?
    var note: String?
    var expireAt: Int64?
    var sortOrder: Int
    var status: String
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool

    enum CodingKeys: String, CodingKey {
        case uuid, name, address, port, username, icon, color, note, status, tags
        case authKind = "auth_kind"
        case credentialRef = "credential_ref"
        case keyUUID = "key_uuid"
        case jumpChain = "jump_chain"
        case expireAt = "expire_at"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
    }
}

extension HostRecord {
    init(_ host: DomainHost) {
        uuid = host.id
        name = host.name
        address = host.address
        port = host.port
        username = host.username
        authKind = host.authKind.rawValue
        credentialRef = host.credentialRef
        keyUUID = host.keyUUID
        jumpChain = Self.encodeJSON(host.jumpChain)
        tags = Self.encodeJSON(host.tags)
        icon = host.icon
        color = host.color
        note = host.note
        expireAt = host.expireAt
        sortOrder = host.sortOrder
        status = host.status.rawValue
        createdAt = host.createdAt
        updatedAt = host.updatedAt
        syncDirty = host.syncDirty
    }

    func toDomain(groupIDs: [String] = []) -> DomainHost {
        guard let parsedAuthKind = DomainHost.AuthKind(rawValue: authKind) else {
            preconditionFailure("未知主机认证方式：\(authKind)")
        }
        return DomainHost(
            id: uuid,
            name: name,
            address: address,
            username: username,
            port: port,
            authKind: parsedAuthKind,
            credentialRef: credentialRef,
            keyUUID: keyUUID,
            jumpChain: Self.decodeJSON(jumpChain),
            groupIDs: groupIDs,
            tags: Self.decodeJSON(tags),
            icon: icon,
            color: color,
            note: note,
            expireAt: expireAt,
            sortOrder: sortOrder,
            status: DomainHost.HealthStatus(rawValue: status) ?? .unknown,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }

    private static func encodeJSON(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8)
        else { return "[]" }
        return string
    }

    private static func decodeJSON(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }
}
