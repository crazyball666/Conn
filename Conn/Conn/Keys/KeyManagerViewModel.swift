import ConnCrypto
import ConnKit
import Foundation
import Observation

/// 密钥管家 ViewModel（原型 S9）。
@Observable
@MainActor
final class KeyManagerViewModel {
    private(set) var keys: [SSHKey] = []
    var lastError: String?

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
    /// 删除前提示用。数据库也会在删除事务中再次检查引用。
    func hostCount(using key: SSHKey) -> Int {
        ((try? hostStore.allHosts()) ?? []).count { $0.keyUUID == key.id }
    }

    func load() {
        let databaseKeys = (try? keyStore.allKeys()) ?? []
        let keychainKeys = (try? credentialStore.allKeyMetadata()) ?? []
        let databaseIDs = Set(databaseKeys.map(\.id))
        let keychainByID = Dictionary(uniqueKeysWithValues: keychainKeys.map { ($0.id, $0) })

        // 升级前已有的数据库密钥，首次加载时补写元数据索引。
        for key in databaseKeys where keychainByID[key.id] == nil {
            try? credentialStore.setKeyMetadata(key, forKey: key.id)
        }

        // 卸载重装后 SQLite 元数据不存在：从 Keychain 恢复回数据库，
        // 同时保留恢复结果，即使本次数据库写入暂时失败，页面仍可展示密钥。
        let recoveredKeys = keychainKeys.filter { !databaseIDs.contains($0.id) }
        for key in recoveredKeys {
            try? keyStore.save(key)
        }
        keys = (databaseKeys + recoveredKeys).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    /// 生成一把新密钥：公钥/元数据入库，私钥材料存 Keychain。
    @discardableResult
    func generateEd25519(name: String) -> SSHKey? {
        generate(kind: .ed25519, name: name)
    }

    @discardableResult
    func generate(kind: SSHKey.Kind, name: String) -> SSHKey? {
        let comment = "conn@\(name.isEmpty ? "device" : name)"
        let generated: GeneratedKey
        do {
            switch kind {
            case .ed25519:
                generated = SSHKeyGenerator.generateEd25519(comment: comment)
            case .rsa:
                generated = try SSHKeyGenerator.generateRSA4096(comment: comment)
            case .ecdsaP256:
                generated = SSHKeyGenerator.generateECDSAP256(comment: comment)
            }
        } catch {
            lastError = "\(L("密钥生成失败"))：\(error)"
            return nil
        }
        let keyID = UUID().uuidString

        let key = SSHKey(
            id: keyID,
            name: name.isEmpty ? L("新密钥") : name,
            kind: generated.kind,
            publicKey: generated.publicKeyOpenSSH,
            privateRef: "conn.key.\(keyID).private"
        )
        do {
            try credentialStore.setPrivateKey(generated.keychainMaterial, forKey: keyID)
            try credentialStore.setKeyMetadata(key, forKey: keyID)
            try keyStore.save(key)
            load()
            return key
        } catch {
            lastError = "\(L("密钥保存失败"))：\(error)"
            return nil
        }
    }

    @discardableResult
    func importPrivateKey(name: String, kind: SSHKey.Kind, text: String) -> SSHKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("ENCRYPTED") else {
            lastError = L("不支持加密私钥，请导入未加密的 PEM/PKCS#8 私钥")
            return nil
        }
        let comment = "conn@\(name.isEmpty ? "imported" : name)"
        do {
            let generated: GeneratedKey
            switch kind {
            case .rsa:
                generated = try SSHKeyGenerator.rsa4096(fromPEM: trimmed, comment: comment)
            case .ed25519:
                if trimmed.contains("BEGIN ") {
                    generated = try SSHKeyGenerator.ed25519(fromPEM: trimmed, comment: comment)
                } else if let raw = Data(base64Encoded: trimmed) {
                    generated = try SSHKeyGenerator.ed25519(fromRawPrivateKey: raw, comment: comment)
                } else {
                    throw CredentialError.encoding
                }
            case .ecdsaP256:
                if let raw = Data(base64Encoded: trimmed) {
                    generated = try SSHKeyGenerator.ecdsaP256(fromRawPrivateKey: raw, comment: comment)
                } else {
                    generated = try SSHKeyGenerator.ecdsaP256(fromPEM: trimmed, comment: comment)
                }
            }
            let keyID = UUID().uuidString
            let key = SSHKey(
                id: keyID,
                name: name.isEmpty ? L("导入密钥") : name,
                kind: generated.kind,
                publicKey: generated.publicKeyOpenSSH,
                privateRef: "conn.key.\(keyID).private"
            )
            try credentialStore.setPrivateKey(generated.keychainMaterial, forKey: keyID)
            try credentialStore.setKeyMetadata(key, forKey: keyID)
            try keyStore.save(key)
            load()
            return key
        } catch CredentialError.encryptedPrivateKey {
            lastError = L("不支持加密私钥（密码短语），请导入未加密私钥")
            return nil
        } catch {
            lastError = "\(L("私钥导入失败"))：\(error)"
            return nil
        }
    }

    func delete(_ key: SSHKey) {
        do {
            try keyStore.delete(id: key.id)
            try credentialStore.setPrivateKey(nil, forKey: key.id)
            try credentialStore.setKeyMetadata(nil, forKey: key.id)
        } catch {
            lastError = "\(L("密钥删除失败"))：\(error)"
        }
        load()
    }

    /// 修改密钥显示名称。SQLite 缓存与 Keychain 元数据索引同时更新，
    /// 不会触碰 Keychain 中的私钥材料。
    @discardableResult
    func rename(_ key: SSHKey, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var updated = key
        updated.name = trimmed
        do {
            try keyStore.save(updated)
            try credentialStore.setKeyMetadata(updated, forKey: key.id)
            load()
            return true
        } catch {
            lastError = "\(L("密钥保存失败"))：\(error)"
            return false
        }
    }

    /// 取某密钥的公钥文本（复制/部署用）。
    func publicKey(for key: SSHKey) -> String {
        key.publicKey
    }

    /// 仅在详情页用户明确点击后读取私钥，用于复制或导出。
    func privateMaterial(for key: SSHKey) -> String? {
        try? credentialStore.privateKey(forKey: key.id)
    }
}
