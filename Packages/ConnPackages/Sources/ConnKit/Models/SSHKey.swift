import Foundation

/// 一把 SSH 密钥。
///
/// **私钥绝不存在本类型中**——`privateRef` 是 Keychain / Secure Enclave 的
/// 引用键。Secure Enclave 密钥（`.secureEnclaveP256`）的私钥物理上不可导出。
public struct SSHKey: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ed25519
        case rsa
        case secureEnclaveP256 = "se_p256"

        /// OpenSSH `authorized_keys` 中的算法前缀。
        public var opensshPrefix: String {
            switch self {
            case .ed25519: "ssh-ed25519"
            case .rsa: "ssh-rsa"
            case .secureEnclaveP256: "ecdsa-sha2-nistp256"
            }
        }

        /// 私钥是否可导出。Secure Enclave 密钥永远不可导出。
        public var isExportable: Bool { self != .secureEnclaveP256 }
    }

    public let id: String
    public var name: String
    public var kind: Kind
    /// OpenSSH 格式公钥（含算法前缀与 base64 主体）。
    public var publicKey: String
    /// Keychain / Secure Enclave 引用键，非私钥本身。
    public var privateRef: String?
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: Kind,
        publicKey: String,
        privateRef: String? = nil,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
        self.privateRef = privateRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
    }

    /// 是否存于 Secure Enclave。UI 上需展示专属徽章（原型 S9）。
    public var isSecureEnclave: Bool { kind == .secureEnclaveP256 }
}
