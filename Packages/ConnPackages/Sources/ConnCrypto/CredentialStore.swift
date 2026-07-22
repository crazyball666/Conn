import Foundation

/// 主机凭据（密码、密钥 passphrase）的安全存取。
///
/// **红线**：凭据只存 Keychain，密文绝不入 SQLite。本协议是唯一出口，
/// 其他层不得直接触碰 Keychain。演示模式与测试注入内存实现。
///
/// 本 Phase（3）只覆盖密码与 passphrase；Phase 5 在同一 target 扩展密钥
/// 生成、Secure Enclave、一键部署。
public protocol CredentialStore: Sendable {
    /// 存一台主机的登录密码。传 nil 删除。
    func setPassword(_ password: String?, forHost hostID: String) throws
    func password(forHost hostID: String) throws -> String?

    /// 存一台主机所用密钥的 passphrase。传 nil 删除。
    func setPassphrase(_ passphrase: String?, forHost hostID: String) throws
    func passphrase(forHost hostID: String) throws -> String?

    /// 删除某主机的全部凭据（主机被删除时调用）。
    func deleteAll(forHost hostID: String) throws

    /// 存一把密钥的私钥材料（原始字节的 base64，或导入的 PEM）。传 nil 删除。
    func setPrivateKey(_ material: String?, forKey keyID: String) throws
    func privateKey(forKey keyID: String) throws -> String?
}

/// 凭据存取错误。
public enum CredentialError: Error, Equatable {
    /// Keychain 操作失败，带 OSStatus。
    case keychain(status: Int32)
    /// 数据编码异常。
    case encoding
}
