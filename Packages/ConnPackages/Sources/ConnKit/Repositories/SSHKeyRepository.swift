import Foundation

/// SSH 密钥仓库协议（元数据；私钥材料在 Keychain）。
public protocol SSHKeyRepository: Sendable {
    func allKeys() throws -> [SSHKey]
    func key(id: String) throws -> SSHKey?
    func save(_ key: SSHKey) throws
    func softDelete(id: String) throws
}
