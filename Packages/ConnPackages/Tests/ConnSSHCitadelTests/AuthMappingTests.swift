import ConnCrypto
import ConnSSH
import Testing
@testable import ConnSSHCitadel

@Suite("密钥认证材料映射")
struct AuthMappingTests {
    @Test("生成的 Ed25519 OpenSSH 私钥可交给 Citadel")
    func generatedEd25519OpenSSHIsAccepted() throws {
        let generated = SSHKeyGenerator.generateEd25519()
        let pem = try #require(generated.privateKeyPEM)
        let auth = SSHAuth.key(SSHPrivateKeyMaterial(kind: .ed25519, pem: pem))
        _ = try AuthMapping.method(for: auth, username: "deploy")
    }

    @Test("生成的 RSA OpenSSH 私钥可交给 Citadel")
    func generatedRSAOpenSSHIsAccepted() throws {
        let generated = try SSHKeyGenerator.generateRSA4096()
        let pem = try #require(generated.privateKeyPEM)
        let auth = SSHAuth.key(SSHPrivateKeyMaterial(kind: .rsa, pem: pem))
        _ = try AuthMapping.method(for: auth, username: "deploy")
    }

    @Test("生成的 ECDSA P-256 PEM 私钥可交给 Citadel")
    func generatedECDSAPEMIsAccepted() throws {
        let generated = SSHKeyGenerator.generateECDSAP256()
        let pem = try #require(generated.privateKeyPEM)
        let auth = SSHAuth.key(SSHPrivateKeyMaterial(kind: .ecdsaP256, pem: pem))
        _ = try AuthMapping.method(for: auth, username: "deploy")
    }
}
