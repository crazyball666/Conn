import Foundation
import Security
import ConnKit

/// Keychain 支撑的凭据存储（技术方案 §3 Keychain 存储规范）。
///
/// 可访问性 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`——设备解锁时可读、
/// 不随 iCloud Keychain 同步（同步走 E2E 通道，不走系统 Keychain 同步）。
/// 条目 account 形如 `conn.host.<uuid>.password` 或 `conn.key.<uuid>.metadata`。
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    /// - Parameter service: Keychain service 标识，默认 App bundle 级命名空间。
    public init(service: String = "com.crazyball.Conn.credentials") {
        self.service = service
    }

    // MARK: - 密码

    public func setPassword(_ password: String?, forHost hostID: String) throws {
        try set(password, account: account(hostID, "password"))
    }

    public func password(forHost hostID: String) throws -> String? {
        try get(account: account(hostID, "password"))
    }

    public func deleteAll(forHost hostID: String) throws {
        try delete(account: account(hostID, "password"))
    }

    // MARK: - 密钥私钥材料

    public func setPrivateKey(_ material: String?, forKey keyID: String) throws {
        try set(material, account: "conn.key.\(keyID).private")
    }

    public func privateKey(forKey keyID: String) throws -> String? {
        try get(account: "conn.key.\(keyID).private")
    }

    public func setKeyMetadata(_ key: SSHKey?, forKey keyID: String) throws {
        let account = keyMetadataAccount(keyID)
        guard let key else {
            try delete(account: account)
            return
        }
        let data = try JSONEncoder().encode(key)
        try set(data, account: account)
    }

    public func allKeyMetadata() throws -> [SSHKey] {
        try allKeychainEntries().compactMap { entry in
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasSuffix(".metadata"),
                  let data = entry[kSecValueData as String] as? Data else { return nil }
            return try JSONDecoder().decode(SSHKey.self, from: data)
        }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }
    }

    /// 恢复旧版本只保存了私钥、没有保存元数据的 Keychain 条目。
    /// 仅用于升级/重装后的启动恢复；无法推断算法的条目会被安全跳过。
    public func recoverLegacyKeyMetadata() throws -> [SSHKey] {
        let knownIDs = Set(try allKeyMetadata().map(\.id))
        var recovered: [SSHKey] = []

        for entry in try allKeychainEntries() {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix("conn.key."),
                  account.hasSuffix(".private"),
                  let data = entry[kSecValueData as String] as? Data,
                  let material = String(data: data, encoding: .utf8) else { continue }

            let id = String(account.dropFirst("conn.key.".count).dropLast(".private".count))
            guard !id.isEmpty, !knownIDs.contains(id),
                  let key = recoverLegacyKey(id: id, material: material) else { continue }
            try setKeyMetadata(key, forKey: id)
            recovered.append(key)
        }

        return recovered.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    // MARK: - Keychain 原语

    private func account(_ hostID: String, _ kind: String) -> String {
        "conn.host.\(hostID).\(kind)"
    }

    private func keyMetadataAccount(_ keyID: String) -> String {
        "conn.key.\(keyID).metadata"
    }

    private func allKeychainEntries() throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return []
        case errSecSuccess:
            return item as? [[String: Any]] ?? []
        default:
            throw CredentialError.keychain(status: status)
        }
    }

    private func recoverLegacyKey(id: String, material: String) -> SSHKey? {
        let comment = "recovered@conn"
        let generated: GeneratedKey?
        if material.contains("BEGIN ") {
            generated = (try? SSHKeyGenerator.ed25519(fromPEM: material, comment: comment))
                ?? (try? SSHKeyGenerator.rsa4096(fromPEM: material, comment: comment))
                ?? (try? SSHKeyGenerator.ecdsaP256(fromPEM: material, comment: comment))
        } else if let raw = Data(base64Encoded: material) {
            generated = (try? SSHKeyGenerator.ed25519(fromRawPrivateKey: raw, comment: comment))
                ?? (try? SSHKeyGenerator.ecdsaP256(fromRawPrivateKey: raw, comment: comment))
        } else {
            generated = nil
        }
        guard let generated else { return nil }
        return SSHKey(
            id: id,
            name: "恢复的 \(generated.kind.displayName) 密钥",
            kind: generated.kind,
            publicKey: generated.publicKeyOpenSSH,
            privateRef: "conn.key.\(id).private"
        )
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// 写入或删除（value 为 nil 时删除）。优先原子更新，只有条目不存在时才新增。
    private func set(_ value: String?, account: String) throws {
        guard let value else {
            try delete(account: account)
            return
        }
        guard let data = value.data(using: .utf8) else {
            throw CredentialError.encoding
        }
        try upsert(data: data, account: account)
    }

    private func set(_ data: Data, account: String) throws {
        try upsert(data: data, account: account)
    }

    /// 原子覆盖 Keychain 条目。先 Update 可以保留旧值直到新值被系统接受，
    /// 避免 delete + add 在第二步失败时造成不可恢复的凭据丢失。
    private func upsert(data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else {
            guard updateStatus == errSecSuccess else {
                throw CredentialError.keychain(status: updateStatus)
            }
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychain(status: status)
        }
    }

    private func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                throw CredentialError.encoding
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialError.keychain(status: status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status: status)
        }
    }
}
