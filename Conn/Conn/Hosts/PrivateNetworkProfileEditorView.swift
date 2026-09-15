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
    @State private var headscaleControlURL: String
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
        _headscaleControlURL = State(initialValue: initialProfile?.provider == .headscale ? initialProfile?.controlURL ?? "" : "")
        _authKey = State(initialValue: initialProfile.flatMap {
            try? credentialStore.privateNetworkAuthKey(forProfile: $0.id)
        } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("配置")) {
                    ConnectionSettingField(L("名称")) {
                        TextField(L("请填写配置名称"), text: $name)
                            .accessibilityIdentifier("private-network-profile.name")
                    }
                    Picker(L("服务"), selection: $provider) {
                        Text(L("Tailscale")).tag(PrivateNetworkProfile.Provider.tailscale)
                        Text(L("Headscale")).tag(PrivateNetworkProfile.Provider.headscale)
                    }
                    .accessibilityIdentifier("private-network-profile.provider")
                    .onChange(of: provider) { oldProvider, newProvider in
                        if oldProvider == .headscale {
                            headscaleControlURL = controlURL
                        }
                        controlURL = newProvider == .tailscale
                            ? "https://controlplane.tailscale.com" : headscaleControlURL
                    }
                    if provider == .headscale {
                        ConnectionSettingField(L("控制端点")) {
                            TextField("https://headscale.example.com", text: $controlURL)
                                .keyboardType(.URL)
                                .accessibilityIdentifier("private-network-profile.control-url")
                        }
                    }
                }
                .listRowBackground(Color.connSurface)
                Section {
                    ConnectionSettingField(L("auth key")) {
                        HStack {
                            Group {
                                if isAuthKeyVisible {
                                    TextField(L("请填写 auth key"), text: $authKey)
                                } else {
                                    SecureField(L("请填写 auth key"), text: $authKey)
                                }
                            }
                            .accessibilityIdentifier("private-network-profile.auth-key")
                            Button {
                                isAuthKeyVisible.toggle()
                            } label: {
                                Image(systemName: isAuthKeyVisible ? "eye.slash" : "eye")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(isAuthKeyVisible ? L("隐藏 auth key") : L("显示 auth key"))
                            .accessibilityIdentifier("private-network-profile.auth-key-visibility")
                        }
                    }
                } header: {
                    Text(L("认证"))
                } footer: {
                    Text(L("auth key 仅保存到设备 Keychain；建议使用可撤销、最小权限的预授权密钥。"))
                }
                .listRowBackground(Color.connSurface)
                Section {
                    Text(L("此配置独立保存，可供多个主机复用。修改会影响使用它的主机。"))
                        .font(.connFootnote).foregroundStyle(.connMuted)
                }
                .listRowBackground(Color.connSurface)
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.connCrit) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
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
