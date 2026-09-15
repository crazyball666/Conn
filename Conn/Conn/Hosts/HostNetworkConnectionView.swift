import ConnKit
import ConnUI
import SwiftUI

/// 修改共享的主机草稿，返回不会提交；仍由主机页统一保存。
struct HostNetworkConnectionView: View {
    @Bindable var viewModel: HostFormViewModel
    let dependencies: AppDependencies
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var profileEditor: PrivateNetworkProfileEditorRequest?
    @State private var isPasswordVisible = false

    var body: some View {
        Form {
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    ForEach(HostNetworkConnectionMode.allCases, id: \.self) { mode in
                        Button { viewModel.selectNetworkConnectionMode(mode) } label: {
                            HStack {
                                Text(mode.title)
                                Spacer()
                                if viewModel.networkConnectionMode == mode { Image(systemName: "checkmark") }
                            }
                            .foregroundStyle(.connInk)
                        }
                        .accessibilityIdentifier("network-route.mode.\(mode.rawValue)")
                        .accessibilityAddTraits(viewModel.networkConnectionMode == mode ? .isSelected : [])
                    }
                } else {
                    Picker(L("连接方式"), selection: Binding(
                        get: { viewModel.networkConnectionMode },
                        set: { viewModel.selectNetworkConnectionMode($0) }
                    )) {
                        ForEach(HostNetworkConnectionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                                .accessibilityIdentifier("network-route.mode.\(mode.rawValue)")
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("network-route.mode")
                }
            } footer: {
                Text(L("仅作用于当前主机的连接，不改变设备的系统网络。"))
            }
            .listRowBackground(Color.connSurface)

            switch viewModel.networkConnectionMode {
            case .direct:
                Section {
                    Label(L("使用设备当前网络连接主机。"), systemImage: "network")
                        .foregroundStyle(.connMuted)
                }
                .listRowBackground(Color.connSurface)
            case .privateNetwork:
                privateNetworkSection
            case .proxy:
                proxySections
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("网络连接"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("network-route.form")
        .sheet(item: $profileEditor) { request in
            PrivateNetworkProfileEditorView(
                profileStore: dependencies.privateNetworkProfileRepository,
                credentialStore: dependencies.credentialStore,
                initialProfile: request.profile
            ) { profile in
                viewModel.reloadPrivateNetworkProfiles()
                viewModel.selectPrivateNetworkProfile(profile.id)
            }
        }
    }

    private var privateNetworkSection: some View {
        Section {
            if viewModel.availablePrivateNetworkProfiles.isEmpty {
                Text(L("暂无私有网络配置")).foregroundStyle(.connMuted)
            } else {
                Picker(L("配置"), selection: Binding(
                    get: { viewModel.draft.privateNetworkProfileID ?? "" },
                    set: { viewModel.selectPrivateNetworkProfile($0.isEmpty ? nil : $0) }
                )) {
                    Text(L("请选择配置")).tag("")
                    ForEach(viewModel.availablePrivateNetworkProfiles) { profile in
                        Text("\(profile.name) · \(profile.provider == .tailscale ? L("Tailscale") : L("Headscale"))")
                            .tag(profile.id)
                    }
                }
                .accessibilityIdentifier("host-form.private-network")
            }
            if let profile = viewModel.selectedPrivateNetworkProfile {
                Button { profileEditor = .init(profile: profile) } label: {
                    Label(L("编辑当前配置"), systemImage: "pencil")
                }
                .accessibilityIdentifier("host-form.private-network.edit")
            }
            Button { profileEditor = .init(profile: nil) } label: {
                Label(L("新增私有网络"), systemImage: "plus")
            }
            .accessibilityIdentifier("host-form.private-network.add")
            if let error = viewModel.fieldErrors[.privateNetwork] {
                Text(error).foregroundStyle(.connCrit).font(.connFootnote)
            }
        } header: {
            Text(L("Tailscale / Headscale"))
        } footer: {
            Text(L("由应用内置节点连接，无需开启系统 VPN。配置可供多个主机复用。"))
        }
        .listRowBackground(Color.connSurface)
    }

    @ViewBuilder
    private var proxySections: some View {
        Section {
            if dynamicTypeSize.isAccessibilitySize {
                proxyKindPicker.pickerStyle(.inline)
            } else {
                proxyKindPicker.pickerStyle(.menu)
            }
            ConnectionSettingField(L("地址")) {
                TextField("proxy.example.com", text: proxyBinding(\.host, fallback: ""))
                    .keyboardType(.URL)
                    .accessibilityIdentifier("host-form.proxy-host")
            }
            ConnectionSettingField(L("端口")) {
                TextField("8080", value: proxyBinding(\.port, fallback: 8080), format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("host-form.proxy-port")
            }
        } header: {
            Text(L("代理"))
        } footer: {
            Text(L("通过 HTTP CONNECT 或 SOCKS5 代理隧道访问 SSH。"))
        }
        .listRowBackground(Color.connSurface)
        Section(L("认证")) {
            if dynamicTypeSize.isAccessibilitySize {
                proxyAuthenticationPicker.pickerStyle(.inline)
            } else {
                proxyAuthenticationPicker.pickerStyle(.menu)
            }
            if viewModel.draft.proxyConfiguration?.authentication == .password {
                ConnectionSettingField(L("用户名")) {
                    TextField(L("代理用户名"), text: proxyBinding(\.username, fallback: ""))
                        .accessibilityIdentifier("host-form.proxy-username")
                }
                ConnectionSettingField(L("密码")) {
                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField(L("请输入代理密码"), text: $viewModel.proxyPassword)
                            } else {
                                SecureField(L("请输入代理密码"), text: $viewModel.proxyPassword)
                            }
                        }
                        .textContentType(.password)
                        .accessibilityIdentifier("host-form.proxy-password")
                        Button { isPasswordVisible.toggle() } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isPasswordVisible ? L("隐藏密码") : L("显示密码"))
                        .accessibilityIdentifier("host-form.proxy-password-visibility")
                    }
                }
            }
            if let error = viewModel.fieldErrors[.proxy] {
                Text(error).foregroundStyle(.connCrit).font(.connFootnote)
            }
        }
        .listRowBackground(Color.connSurface)
    }

    private var proxyKindPicker: some View {
        Picker(L("类型"), selection: proxyBinding(\.kind, fallback: .httpConnect)) {
            Text(L("HTTP CONNECT")).fixedSize(horizontal: false, vertical: true)
                .tag(SSHProxyConfiguration.Kind.httpConnect)
            Text(L("SOCKS5")).tag(SSHProxyConfiguration.Kind.socks5)
        }
        .accessibilityIdentifier("host-form.proxy-kind")
    }

    private var proxyAuthenticationPicker: some View {
        Picker(L("认证方式"), selection: proxyBinding(\.authentication, fallback: .none)) {
            Text(L("无")).tag(SSHProxyConfiguration.Authentication.none)
            Text(L("用户名/密码")).fixedSize(horizontal: false, vertical: true)
                .tag(SSHProxyConfiguration.Authentication.password)
        }
        .accessibilityIdentifier("host-form.proxy-authentication")
    }

    private func proxyBinding<Value>(_ keyPath: WritableKeyPath<SSHProxyConfiguration, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { viewModel.draft.proxyConfiguration.map { $0[keyPath: keyPath] } ?? fallback },
            set: { value in
                guard var proxy = viewModel.draft.proxyConfiguration else { return }
                proxy[keyPath: keyPath] = value
                viewModel.draft.proxyConfiguration = proxy
            }
        )
    }
}

/// 持久字段标签不随输入消失，长标签和辅助字号也不挤压输入框。
struct ConnectionSettingField<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.connMuted)
            content
                .foregroundStyle(.connInk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(title)
        }
        .padding(.vertical, 4)
    }
}
