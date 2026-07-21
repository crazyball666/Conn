import Foundation
import Security

/// Keychain 支撑的凭据存储（技术方案 §3 Keychain 存储规范）。
///
/// 可访问性 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`——设备解锁时可读、
/// 不随 iCloud Keychain 同步（同步走 E2E 通道，不走系统 Keychain 同步）。
/// 条目 account 形如 `conn.host.<uuid>.password`。
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

    // MARK: - passphrase

    public func setPassphrase(_ passphrase: String?, forHost hostID: String) throws {
        try set(passphrase, account: account(hostID, "passphrase"))
    }

    public func passphrase(forHost hostID: String) throws -> String? {
        try get(account: account(hostID, "passphrase"))
    }

    public func deleteAll(forHost hostID: String) throws {
        try delete(account: account(hostID, "password"))
        try delete(account: account(hostID, "passphrase"))
    }

    // MARK: - Keychain 原语

    private func account(_ hostID: String, _ kind: String) -> String {
        "conn.host.\(hostID).\(kind)"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// 写入或删除（value 为 nil 时删除）。用 delete + add 保证幂等覆盖。
    private func set(_ value: String?, account: String) throws {
        guard let value else {
            try delete(account: account)
            return
        }
        guard let data = value.data(using: .utf8) else {
            throw CredentialError.encoding
        }
        try delete(account: account) // 幂等：先清旧值

        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
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
