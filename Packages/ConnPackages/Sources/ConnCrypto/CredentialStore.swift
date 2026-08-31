import ConnKit
import Foundation

/// 主机凭据（密码、密钥私钥）的安全存取。
///
/// **红线**：凭据只存 Keychain，密文绝不入 SQLite。本协议是唯一出口，
/// 其他层不得直接触碰 Keychain。测试注入内存实现。
///
/// 密钥私钥材料只通过 Keychain 引用读取，绝不写入 SQLite。
public protocol CredentialStore: Sendable {
    /// 存一台主机的登录密码。传 nil 删除。
    func setPassword(_ password: String?, forHost hostID: String) throws
    func password(forHost hostID: String) throws -> String?

    /// 删除某主机的全部凭据（主机被删除时调用）。
    func deleteAll(forHost hostID: String) throws

    /// 存一把密钥的私钥材料（原始字节的 base64，或导入的 PEM）。传 nil 删除。
    func setPrivateKey(_ material: String?, forKey keyID: String) throws
    func privateKey(forKey keyID: String) throws -> String?

    /// 存储密钥列表所需的非敏感元数据。元数据也放在 Keychain，
    /// 这样卸载应用后仍能恢复名称、算法和公钥；私钥材料仍单独保存。
    func setKeyMetadata(_ key: SSHKey?, forKey keyID: String) throws
    func allKeyMetadata() throws -> [SSHKey]
}

/// 凭据存取错误。
public enum CredentialError: Error, Equatable {
    /// Keychain 操作失败，带 OSStatus。
    case keychain(status: Int32)
    /// 数据编码异常。
    case encoding
    /// 私钥使用了密码短语或其它加密容器；当前产品不保存密码短语。
    case encryptedPrivateKey
}
