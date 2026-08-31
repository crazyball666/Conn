import Foundation
import ConnKit

/// 内存凭据存储（测试用）。
///
/// 与 `KeychainCredentialStore` 同语义，但不落地，避免测试写入真实 Keychain。
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var passwords: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func setPassword(_ password: String?, forHost hostID: String) throws {
        lock.withLock { passwords[hostID] = password }
    }

    public func password(forHost hostID: String) throws -> String? {
        lock.withLock { passwords[hostID] }
    }

    public func deleteAll(forHost hostID: String) throws {
        lock.withLock {
            passwords[hostID] = nil
        }
    }

    private var privateKeys: [String: String] = [:]

    public func setPrivateKey(_ material: String?, forKey keyID: String) throws {
        lock.withLock { privateKeys[keyID] = material }
    }

    public func privateKey(forKey keyID: String) throws -> String? {
        lock.withLock { privateKeys[keyID] }
    }

    private var keyMetadata: [String: SSHKey] = [:]

    public func setKeyMetadata(_ key: SSHKey?, forKey keyID: String) throws {
        lock.withLock { keyMetadata[keyID] = key }
    }

    public func allKeyMetadata() throws -> [SSHKey] {
        lock.withLock {
            keyMetadata.values.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }
        }
    }
}
