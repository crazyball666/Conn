import ConnCrypto
import ConnKit
import ConnSSH
import ConnUI
import SwiftUI

struct PrivateNetworkProfileEditorRequest: Identifiable {
    let profile: PrivateNetworkProfile?
    var id: String { profile?.id ?? "new" }
}

/// Tailscale/Headscale profile editor. Auth keys never enter SQLite or the host model.
struct PrivateNetworkProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let profileStore: any PrivateNetworkProfileRepository
    private let credentialStore: any CredentialStore
    private let initialProfile: PrivateNetworkProfile?
    private let onSaved: @MainActor (PrivateNetworkProfile) -> Void

    @State private var name: String
    @State private var provider: PrivateNetworkProfile.Provider
    @State private var controlURL: String
    @State private var authKey: String
    @State private var errorMessage: String?
    @State private var isAuthKeyVisible = false

    init(
        profileStore: any PrivateNetworkProfileRepository,
        credentialStore: any CredentialStore,
        initialProfile: PrivateNetworkProfile? = nil,
        onSaved: @escaping @MainActor (PrivateNetworkProfile) -> Void
    ) {
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.initialProfile = initialProfile
        self.onSaved = onSaved
        _name = State(initialValue: initialProfile?.name ?? "")
        _provider = State(initialValue: initialProfile?.provider ?? .tailscale)
        _controlURL = State(initialValue: initialProfile?.controlURL ?? "https://controlplane.tailscale.com")
        _authKey = State(initialValue: initialProfile.flatMap {
            try? credentialStore.privateNetworkAuthKey(forProfile: $0.id)
        } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("配置")) {
                    TextField(L("名称"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("private-network-profile.name")
                    Picker(L("服务"), selection: $provider) {
                        Text(L("Tailscale")).tag(PrivateNetworkProfile.Provider.tailscale)
                        Text(L("Headscale")).tag(PrivateNetworkProfile.Provider.headscale)
                    }
                    .onChange(of: provider) { _, newProvider in
                        if newProvider == .headscale,
                           controlURL == "https://controlplane.tailscale.com" {
                            controlURL = ""
                        } else if newProvider == .tailscale, controlURL.isEmpty {
                            controlURL = "https://controlplane.tailscale.com"
                        }
                    }
                    TextField(L("控制端点"), text: $controlURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("private-network-profile.control-url")
                }
                Section(L("认证")) {
                    HStack {
                        Group {
                            if isAuthKeyVisible {
                                TextField(L("auth key"), text: $authKey)
                            } else {
                                SecureField(L("auth key"), text: $authKey)
                            }
                        }
                        Button {
                            isAuthKeyVisible.toggle()
                        } label: {
                            Image(systemName: isAuthKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isAuthKeyVisible ? L("隐藏 auth key") : L("显示 auth key"))
                    }
                    Text(L("auth key 仅保存到设备 Keychain；建议使用可撤销、最小权限的预授权密钥。"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.connCrit) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(initialProfile == nil ? L("新增私有网络") : L("编辑私有网络"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .accessibilityIdentifier("private-network-profile.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存")) { save() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("private-network-profile.save")
                }
            }
        }
    }

    private func save() {
        let profile = PrivateNetworkProfile(
            id: initialProfile?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider,
            controlURL: controlURL.trimmingCharacters(in: .whitespacesAndNewlines),
            authKeyRef: initialProfile?.authKeyRef
        )
        if let validationError = profile.validationError {
            errorMessage = validationError == .emptyName
                ? L("请填写配置名称")
                : L("控制端点必须是有效的 HTTPS 地址")
            return
        }
        let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = L("请填写 auth key")
            return
        }

        do {
            let oldKey = try credentialStore.privateNetworkAuthKey(forProfile: profile.id)
            try credentialStore.setPrivateNetworkAuthKey(key, forProfile: profile.id)
            do {
                try profileStore.save(profile)
            } catch {
                try? credentialStore.setPrivateNetworkAuthKey(oldKey, forProfile: profile.id)
                throw error
            }
            onSaved(profile)
            dismiss()
        } catch {
            errorMessage = String(format: L("保存私有网络失败：%@"), error.friendlyDiagnosis)
        }
    }
}
