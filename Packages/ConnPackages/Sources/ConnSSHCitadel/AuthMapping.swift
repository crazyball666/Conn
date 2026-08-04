import Citadel
import ConnKit
import ConnSSH
import Crypto
import Foundation
import NIOSSH

/// `SSHAuth` ↔ Citadel 认证方法的映射，以及连接错误 → `SSHError` 的诊断映射。
enum AuthMapping {
    /// 把 Conn 的认证材料转成 Citadel 的 `SSHAuthenticationMethod`。
    ///
    /// - Throws: `SSHError.unsupportedByEngine` 当认证方式 Citadel 不支持
    ///   （keyboard-interactive）；密钥解析失败时抛底层错误。
    static func method(for auth: SSHAuth, username: String) throws -> SSHAuthenticationMethod {
        switch auth {
        case let .password(password):
            return .passwordBased(username: username, password: password)

        case let .key(material):
            return try keyMethod(material, username: username)

        case .keyboardInteractive:
            // S1 结论 R3：Citadel 的 fork 只有 publicKey/password/hostBased。
            throw SSHError.unsupportedByEngine(.keyboardInteractive)
        }
    }

    private static func keyMethod(
        _ material: SSHPrivateKeyMaterial,
        username: String
    ) throws -> SSHAuthenticationMethod {
        switch material.kind {
        case .ed25519:
            let key = try ed25519Key(material.representation)
            return .ed25519(username: username, privateKey: key)

        case .rsa:
            // 注意（S1 结论 R2）：Citadel 只会用 ssh-rsa(SHA-1) 签名，连现代
            // 服务器会失败——这在 mapConnectError 里被识别并给 ed25519 建议。
            guard case let .pem(pem) = material.representation else {
                throw SSHError.authFailed(reason: .badCredentials)
            }
            let key = try Insecure.RSA.PrivateKey(sshRsa: pem)
            return .rsa(username: username, privateKey: key)

        case .ecdsaP256:
            let key: P256.Signing.PrivateKey
            switch material.representation {
            case let .raw(raw):
                key = try P256.Signing.PrivateKey(rawRepresentation: raw)
            case let .pem(pem):
                key = try P256.Signing.PrivateKey(pemRepresentation: pem)
            }
            return .p256(username: username, privateKey: key)
        }
    }

    private static func ed25519Key(
        _ representation: SSHPrivateKeyMaterial.Representation
    ) throws -> Curve25519.Signing.PrivateKey {
        switch representation {
        case let .pem(pem):
            try Curve25519.Signing.PrivateKey(sshEd25519: pem)
        case let .raw(data):
            // Conn 生成的密钥：直接用 32 字节原始表示构造。
            try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
    }

    /// 把 Citadel/NIOSSH 的连接错误映射为带诊断的 `SSHError`。
    ///
    /// 关键判断（S1 结论）：认证失败 + RSA 密钥 → 极可能是现代服务器拒绝
    /// ssh-rsa(SHA-1)，给出 ed25519 改用建议而非笼统的「密码错误」。
    static func mapConnectError(_ error: any Error, endpoint: SSHEndpoint, auth: SSHAuth) -> SSHError {
        // 已经是我们的错误类型，直接透传
        if let sshError = error as? SSHError {
            return sshError
        }

        // Citadel host-key validation fails the NIO handshake promise with a wrapper so
        // the precise domain error survives the engine boundary.
        if let validationError = error as? CitadelHostKeyValidationError {
            return validationError.sshError
        }

        let description = String(describing: error).lowercased()

        if description.contains("authentication") || description.contains("auth failed") || description.contains("permission denied") {
            if case let .key(material) = auth, material.kind == .rsa {
                return .authFailed(reason: .rsaSha2Unsupported)
            }
            return .authFailed(reason: .badCredentials)
        }
        if description.contains("connection refused") {
            return .connectionRefused(endpoint: endpoint)
        }
        if description.contains("timed out") || description.contains("timeout") {
            return .timeout(endpoint: endpoint)
        }
        if description.contains("nodename nor servname") || description.contains("name or service not known") {
            return .dnsFailed(host: endpoint.host)
        }
        // 兜底：无法归类的连接错误
        return .connectionRefused(endpoint: endpoint)
    }
}
