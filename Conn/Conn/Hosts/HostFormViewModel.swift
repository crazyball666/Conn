import ConnCrypto
import ConnKit
import ConnSSH
import Foundation
import Observation

/// 主机表单 ViewModel（新增/编辑）。
@Observable
@MainActor
final class HostFormViewModel {
    var draft: HostDraft
    var password = ""
    private(set) var fieldErrors: [HostDraft.Field: String] = [:]

    let editingHostID: String?
    private let hostStore: any HostRepository
    private let credentialStore: any CredentialStore
    private let keyStore: any SSHKeyRepository
    /// 可选分组。表单只做多选，新建分组走服务器页工具栏的「+」菜单。
    private(set) var availableGroups: [HostGroup] = []
    private(set) var availableKeys: [SSHKey] = []

    var isEditing: Bool { editingHostID != nil }
    var title: String { isEditing ? L("编辑主机") : L("添加主机") }

    init(
        draft: HostDraft,
        editingHostID: String?,
        hostStore: any HostRepository,
        credentialStore: any CredentialStore,
        groupStore: any HostGroupRepository,
        keyStore: any SSHKeyRepository
    ) {
        self.draft = draft
        self.editingHostID = editingHostID
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        self.keyStore = keyStore
        availableGroups = (try? groupStore.allGroups()) ?? []
        availableKeys = (try? keyStore.allKeys()) ?? []
        // 编辑时读回已存密码，便于展示与再保存
        if let id = editingHostID {
            password = (try? credentialStore.password(forHost: id)) ?? ""
        }
    }

    /// 尝试从粘贴板文本识别并填充。返回是否识别成功。
    @discardableResult
    func applyPaste(_ text: String) -> Bool {
        guard let parsed = SSHCommandParser.parse(text) else { return false }
        // 只覆盖识别出的字段，保留用户已填的名称等
        draft.address = parsed.address
        draft.username = parsed.username
        draft.port = parsed.port
        if parsed.authKind == .key {
            draft.authKind = .key
        }
        return true
    }

    /// 校验并保存。成功返回定稿后的 Host，失败返回 nil 并填充 fieldErrors。
    @discardableResult
    func save() -> Host? {
        fieldErrors = draft.validate()
        guard fieldErrors.isEmpty else { return nil }

        // 丢掉解析不到现存分组的悬空 id（分组在编辑期间被删是良性竞态）。
        // store 层也会过滤，这里是就近防御。
        draft.groupIDs = draft.groupIDs.filter { id in
            availableGroups.contains { $0.id == id }
        }
        let host = draft.toHost(existingID: editingHostID)
        do {
            try hostStore.save(host)
            // 凭据存 Keychain（红线：不入 SQLite）
            if draft.authKind == .password {
                try credentialStore.setPassword(password.isEmpty ? nil : password, forHost: host.id)
            }
            return host
        } catch {
            return nil
        }
    }

    /// 构造当前草稿对应的认证材料，供连接测试。
    func currentAuth() -> SSHAuth {
        switch draft.authKind {
        case .password:
            return .password(password)
        case .key:
            guard let keyID = draft.keyUUID,
                  let key = try? keyStore.key(id: keyID),
                  let material = try? credentialStore.privateKey(forKey: keyID)
            else { return .password(password) }
            switch key.kind {
            case .ed25519, .ecdsaP256:
                if material.contains("BEGIN ") {
                    return .key(SSHPrivateKeyMaterial(kind: key.kind, pem: material))
                }
                guard let raw = Data(base64Encoded: material) else { return .password(password) }
                return .key(SSHPrivateKeyMaterial(kind: key.kind, raw: raw))
            case .rsa:
                return .key(SSHPrivateKeyMaterial(kind: .rsa, pem: material))
            }
        }
    }
}
