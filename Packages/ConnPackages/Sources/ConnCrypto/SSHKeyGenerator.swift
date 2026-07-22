import ConnKit
import Crypto
import Foundation

/// 一把新生成或已加载的密钥对。
public struct GeneratedKey: Sendable {
    public let kind: SSHKey.Kind
    /// OpenSSH `authorized_keys` 格式公钥（`ssh-ed25519 AAAA... comment`）。
    public let publicKeyOpenSSH: String
    /// SHA256 指纹（`SHA256:base64...`，无 padding），与 `ssh-keygen -lf` 一致。
    public let fingerprint: String
    /// 私钥的原始表示（ed25519 为 32 字节）。存 Keychain，连接时构造签名密钥。
    public let privateKeyRaw: Data

    public init(kind: SSHKey.Kind, publicKeyOpenSSH: String, fingerprint: String, privateKeyRaw: Data) {
        self.kind = kind
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprint = fingerprint
        self.privateKeyRaw = privateKeyRaw
    }
}

/// 密钥生成器（技术方案 §4.7）。
///
/// 本 Phase 做 Ed25519（S1 结论的默认密钥类型，全服务端可用）。RSA 与
/// Secure Enclave P256 在 Phase 5b 补（RSA 用 Security.framework，SE 需真机）。
public enum SSHKeyGenerator {
    /// 生成一把 Ed25519 密钥。
    ///
    /// - Parameter comment: 公钥尾部注释，通常 `conn@设备名` 或用户命名。
    public static func generateEd25519(comment: String = "conn") -> GeneratedKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyBytes = [UInt8](privateKey.publicKey.rawRepresentation)

        let blob = ed25519PublicKeyBlob(publicKeyBytes)
        let base64 = Data(blob).base64EncodedString()
        let publicKeyLine = "ssh-ed25519 \(base64) \(comment)"

        return GeneratedKey(
            kind: .ed25519,
            publicKeyOpenSSH: publicKeyLine,
            fingerprint: Self.fingerprint(ofBlob: blob),
            privateKeyRaw: privateKey.rawRepresentation
        )
    }

    /// 从存储的原始私钥恢复公钥信息（如展示、重新部署）。
    public static func ed25519(fromRawPrivateKey raw: Data, comment: String = "conn") throws -> GeneratedKey {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        let publicKeyBytes = [UInt8](privateKey.publicKey.rawRepresentation)
        let blob = ed25519PublicKeyBlob(publicKeyBytes)
        let base64 = Data(blob).base64EncodedString()
        return GeneratedKey(
            kind: .ed25519,
            publicKeyOpenSSH: "ssh-ed25519 \(base64) \(comment)",
            fingerprint: Self.fingerprint(ofBlob: blob),
            privateKeyRaw: raw
        )
    }

    /// ed25519 公钥 wire blob：string("ssh-ed25519") + string(32 字节公钥)。
    static func ed25519PublicKeyBlob(_ publicKeyBytes: [UInt8]) -> [UInt8] {
        OpenSSHWire.encodeString("ssh-ed25519") + OpenSSHWire.encodeString(publicKeyBytes)
    }

    /// 计算公钥 blob 的 SHA256 指纹（`SHA256:base64`，去 padding）。
    static func fingerprint(ofBlob blob: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(blob))
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }
}
