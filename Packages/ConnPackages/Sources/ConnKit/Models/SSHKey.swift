import Foundation

/// 一把 SSH 密钥。
///
/// **私钥绝不存在本类型中**——`privateRef` 是 Keychain 的引用键。
public struct SSHKey: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ed25519
        case rsa
        case ecdsaP256 = "ecdsa_p256"

        /// OpenSSH `authorized_keys` 中的算法前缀。
        public var opensshPrefix: String {
            switch self {
            case .ed25519: "ssh-ed25519"
            case .rsa: "ssh-rsa"
            case .ecdsaP256: "ecdsa-sha2-nistp256"
            }
        }

        public var displayName: String {
            switch self {
            case .ed25519: "Ed25519"
            case .rsa: "RSA 4096"
            case .ecdsaP256: "ECDSA P-256"
            }
        }

        public var isExportable: Bool { true }
    }

    public let id: String
    public var name: String
    public var kind: Kind
    /// OpenSSH 格式公钥（含算法前缀与 base64 主体）。
    public var publicKey: String
    /// Keychain 引用键，非私钥本身。
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

}
