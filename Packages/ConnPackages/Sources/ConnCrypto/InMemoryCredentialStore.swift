import Foundation

/// 内存凭据存储（演示模式与测试用）。
///
/// 与 `KeychainCredentialStore` 同语义，但不落地——演示模式不应把假凭据
/// 写进真实 Keychain。
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var passwords: [String: String] = [:]
    private var passphrases: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func setPassword(_ password: String?, forHost hostID: String) throws {
        lock.withLock { passwords[hostID] = password }
    }

    public func password(forHost hostID: String) throws -> String? {
        lock.withLock { passwords[hostID] }
    }

    public func setPassphrase(_ passphrase: String?, forHost hostID: String) throws {
        lock.withLock { passphrases[hostID] = passphrase }
    }

    public func passphrase(forHost hostID: String) throws -> String? {
        lock.withLock { passphrases[hostID] }
    }

    public func deleteAll(forHost hostID: String) throws {
        lock.withLock {
            passwords[hostID] = nil
            passphrases[hostID] = nil
        }
    }
}
