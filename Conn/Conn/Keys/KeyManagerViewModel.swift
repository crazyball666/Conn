import ConnCrypto
import ConnKit
import ConnSSH
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
    /// 删除前提示用；真正删除时数据层会在事务内解除这些主机的密钥引用。
    func hostCount(using key: SSHKey) -> Int {
        ((try? hostStore.allHosts()) ?? []).count { $0.keyUUID == key.id }
    }

    func load() {
        lastError = nil
        let databaseKeys: [SSHKey]
        let keychainKeys: [SSHKey]
        do {
            databaseKeys = try keyStore.allKeys()
            keychainKeys = try credentialStore.allKeyMetadata()
        } catch {
            keys = []
            lastError = "\(L("密钥读取失败"))：\(error.friendlyDiagnosis)"
            return
        }
        let databaseIDs = Set(databaseKeys.map(\.id))
        let keychainByID = Dictionary(uniqueKeysWithValues: keychainKeys.map { ($0.id, $0) })

        // SQLite 是当前安装的权威索引；Keychain 里的元数据既用于卸载重装恢复，
        // 也必须在编辑失败/旧版本残留时被修回一致状态。
        for key in databaseKeys {
            guard let keychainKey = keychainByID[key.id] else {
                do {
                    try credentialStore.setKeyMetadata(key, forKey: key.id)
                } catch {
                    lastError = "\(L("密钥元数据保存失败"))：\(error.friendlyDiagnosis)"
                }
                continue
            }
            guard keychainKey != key else { continue }
            do {
                try credentialStore.setKeyMetadata(key, forKey: key.id)
            } catch {
                lastError = "\(L("密钥元数据保存失败"))：\(error.friendlyDiagnosis)"
            }
        }

        // 卸载重装后 SQLite 元数据不存在：从 Keychain 恢复回数据库，
        // 同时保留恢复结果，即使本次数据库写入暂时失败，页面仍可展示密钥。
        let recoveredKeys = keychainKeys.compactMap { key -> SSHKey? in
            guard !databaseIDs.contains(key.id) else { return nil }
            do {
                guard try credentialStore.privateKey(forKey: key.id) != nil else {
                    lastError = "\(L("密钥恢复失败"))：\(L("所选密钥不可用，请重新导入或生成密钥"))"
                    return nil
                }
                try keyStore.save(key)
                return key
            } catch {
                lastError = "\(L("密钥恢复失败"))：\(error.friendlyDiagnosis)"
                return nil
            }
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
            lastError = "\(L("密钥生成失败"))：\(error.friendlyDiagnosis)"
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
            if !cleanupCreatedKey(id: keyID) {
                lastError = "\(L("密钥保存失败"))：\(L("密钥数据清理未完成，请重试"))"
                return nil
            }
            lastError = "\(L("密钥保存失败"))：\(error.friendlyDiagnosis)"
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
        var createdKeyID: String?
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
            createdKeyID = keyID
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
            if let keyID = createdKeyID {
                if !cleanupCreatedKey(id: keyID) {
                    lastError = "\(L("私钥导入失败"))：\(L("密钥数据清理未完成，请重试"))"
                    return nil
                }
            }
            lastError = "\(L("私钥导入失败"))：\(error.friendlyDiagnosis)"
            return nil
        }
    }

    @discardableResult
    func delete(_ key: SSHKey) -> Bool {
        var privateMaterial: String?
        var privateMaterialRemoved = false
        var metadataRemoved = false
        var deleteSucceeded = false
        do {
            privateMaterial = try credentialStore.privateKey(forKey: key.id)
            try credentialStore.setPrivateKey(nil, forKey: key.id)
            privateMaterialRemoved = true
            try credentialStore.setKeyMetadata(nil, forKey: key.id)
            metadataRemoved = true
            do {
                try keyStore.delete(id: key.id)
            } catch {
                throw error
            }
            deleteSucceeded = true
        } catch {
            // 任一步失败都补偿已完成的 Keychain 删除，避免 SQLite 与 Keychain
            // 出现“已删一半”的状态；补偿失败仍保留原始错误供用户重试。
            var compensationFailed = false
            if metadataRemoved {
                do { try credentialStore.setKeyMetadata(key, forKey: key.id) }
                catch { compensationFailed = true }
            }
            if privateMaterialRemoved, let privateMaterial {
                do { try credentialStore.setPrivateKey(privateMaterial, forKey: key.id) }
                catch { compensationFailed = true }
            }
            lastError = compensationFailed
                ? "\(L("密钥删除失败"))：\(L("密钥数据清理未完成，请重试"))"
                : "\(L("密钥删除失败"))：\(error.friendlyDiagnosis)"
        }
        // 失败时保留当前列表和错误提示，避免 load() 清空 lastError 并掩盖删除失败。
        if deleteSucceeded {
            load()
        }
        return deleteSucceeded
    }

    /// 修改密钥显示名称。SQLite 缓存与 Keychain 元数据索引同时更新，
    /// 不会触碰 Keychain 中的私钥材料。
    @discardableResult
    func rename(_ key: SSHKey, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var updated = key
        updated.name = trimmed
        var metadataRollbackFailed = false
        do {
            try credentialStore.setKeyMetadata(updated, forKey: key.id)
            do {
                try keyStore.save(updated)
            } catch {
                // Keychain 已先更新，数据库失败时恢复旧元数据，保证下次
                // 启动不会从 Keychain 读到与 SQLite 不同的名称。
                do {
                    try credentialStore.setKeyMetadata(key, forKey: key.id)
                } catch {
                    metadataRollbackFailed = true
                }
                throw error
            }
            load()
            return true
        } catch {
            lastError = metadataRollbackFailed
                ? L("密钥数据清理未完成，请重试")
                : "\(L("密钥保存失败"))：\(error.friendlyDiagnosis)"
            return false
        }
    }

    /// 取某密钥的公钥文本（复制/部署用）。
    func publicKey(for key: SSHKey) -> String {
        key.publicKey
    }

    /// 仅在详情页用户明确点击后读取私钥，用于复制或导出。
    func privateMaterial(for key: SSHKey) -> String? {
        do {
            return try credentialStore.privateKey(forKey: key.id)
        } catch {
            lastError = "\(L("私钥读取失败"))：\(error.friendlyDiagnosis)"
            return nil
        }
    }

    private func cleanupCreatedKey(id: String) -> Bool {
        var succeeded = true
        do { try credentialStore.setPrivateKey(nil, forKey: id) }
        catch { succeeded = false }
        do { try credentialStore.setKeyMetadata(nil, forKey: id) }
        catch { succeeded = false }
        do { try keyStore.delete(id: id) }
        catch { succeeded = false }
        return succeeded
    }
}
