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
    var passphrase = ""
    var showAdvanced = false
    private(set) var fieldErrors: [HostDraft.Field: String] = [:]

    let editingHostID: String?
    private let hostStore: any HostRepository
    private let credentialStore: any CredentialStore

    var isEditing: Bool { editingHostID != nil }
    var title: String { isEditing ? L("编辑主机") : L("添加主机") }

    init(
        draft: HostDraft,
        editingHostID: String?,
        hostStore: any HostRepository,
        credentialStore: any CredentialStore
    ) {
        self.draft = draft
        self.editingHostID = editingHostID
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        // 编辑时读回已存密码，便于展示与再保存
        if let id = editingHostID {
            password = (try? credentialStore.password(forHost: id)) ?? ""
            passphrase = (try? credentialStore.passphrase(forHost: id)) ?? ""
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

        let host = draft.toHost(existingID: editingHostID)
        do {
            try hostStore.save(host)
            // 凭据存 Keychain（红线：不入 SQLite）
            if draft.authKind == .password {
                try credentialStore.setPassword(password.isEmpty ? nil : password, forHost: host.id)
            }
            if draft.authKind == .keyPassphrase {
                try credentialStore.setPassphrase(passphrase.isEmpty ? nil : passphrase, forHost: host.id)
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
            .password(password)
        case .key, .keyPassphrase, .agent:
            // 密钥认证的连接测试待 Phase 5 密钥管家；此处先用密码兜底
            .password(password)
        }
    }
}
