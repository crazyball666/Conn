import ConnCrypto
import ConnKit
import Foundation
import Observation

/// 密钥管家 ViewModel（原型 S9）。
@Observable
@MainActor
final class KeyManagerViewModel {
    private(set) var keys: [SSHKey] = []

    private let keyStore: any SSHKeyRepository
    private let credentialStore: any CredentialStore
    private let hostStore: any HostRepository

    init(
        keyStore: any SSHKeyRepository,
        credentialStore: any CredentialStore,
        hostStore: any HostRepository
    ) {
        self.keyStore = keyStore
        self.credentialStore = credentialStore
        self.hostStore = hostStore
    }

    /// 正在使用该密钥的主机台数。
    ///
    /// 删除前提示用——`host.key_uuid` 的外键是 `ON DELETE SET NULL`，
    /// 改真删除后它第一次会真正触发：删掉密钥会把这些主机的认证方式静默清空，
    /// 用户下次连接才会发现连不上且看不出原因。
    func hostCount(using key: SSHKey) -> Int {
        ((try? hostStore.allHosts()) ?? []).count { $0.keyUUID == key.id }
    }

    func load() {
        keys = (try? keyStore.allKeys()) ?? []
    }

    /// 生成一把新 Ed25519 密钥：公钥/元数据入库，私钥原始表示存 Keychain。
    @discardableResult
    func generateEd25519(name: String) -> SSHKey? {
        let comment = "conn@\(name.isEmpty ? "device" : name)"
        let generated = SSHKeyGenerator.generateEd25519(comment: comment)
        let keyID = UUID().uuidString

        let key = SSHKey(
            id: keyID,
            name: name.isEmpty ? L("新密钥") : name,
            kind: .ed25519,
            publicKey: generated.publicKeyOpenSSH,
            privateRef: "conn.key.\(keyID).private"
        )
        do {
            // 私钥原始字节的 base64 → Keychain（红线：不入 SQLite）
            try credentialStore.setPrivateKey(generated.privateKeyRaw.base64EncodedString(), forKey: keyID)
            try keyStore.save(key)
            load()
            return key
        } catch {
            return nil
        }
    }

    func delete(_ key: SSHKey) {
        try? keyStore.delete(id: key.id)
        try? credentialStore.setPrivateKey(nil, forKey: key.id)
        load()
    }

    /// 取某密钥的公钥文本（复制/部署用）。
    func publicKey(for key: SSHKey) -> String {
        key.publicKey
    }
}
