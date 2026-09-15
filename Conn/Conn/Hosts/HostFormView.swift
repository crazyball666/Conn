import ConnKit
import ConnSSH
import ConnUI
import SwiftUI

/// 主机新增/编辑表单。
///
/// 布局采用 Apple 分组表单惯例（`Form` + `insetGrouped`）：**左字段名、右填内容**，
/// 字段名固定列宽对齐。名称提到最前（便于记忆），端口等不再藏进「高级选项」。
struct HostFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: HostFormViewModel
    @State private var showDiagnostics = false
    @State private var diagnosticsHops: [SSHJumpHop] = []
    @State private var diagnosticsError: String?
    @State private var isGroupExpanded = false
    @State private var isAdvancedExpanded = false
    @State private var isPasswordVisible = false
    @State private var isProxyPasswordVisible = false
    @State private var privateNetworkProfileEditorRequest: PrivateNetworkProfileEditorRequest?
    @FocusState private var focus: HostDraft.Field?
    private let dependencies: AppDependencies
    private let onSaved: @MainActor (HostFormSaveResult) -> Void

    /// 字段名列宽：容纳「用户名 / 认证方式」等最长 4 个汉字，全表左对齐。
    private let labelWidth: CGFloat = 76

    init(
        dependencies: AppDependencies,
        initialDraft: HostDraft,
        editingHostID: String?,
        onSaved: @escaping @MainActor (HostFormSaveResult) -> Void
    ) {
        self.dependencies = dependencies
        self.onSaved = onSaved
        _isAdvancedExpanded = State(initialValue: initialDraft.privateNetworkProfileID != nil
            || initialDraft.proxyConfiguration != nil
            || !initialDraft.jumpChain.isEmpty)
        _viewModel = State(initialValue: HostFormViewModel(
            draft: initialDraft,
            editingHostID: editingHostID,
            hostStore: dependencies.hostRepository,
            credentialStore: dependencies.credentialStore,
            groupStore: dependencies.hostGroupRepository,
            keyStore: dependencies.keyRepository,
            privateNetworkProfileStore: dependencies.privateNetworkProfileRepository
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                pasteSection
                identitySection
                connectionSection
                authSection
                testSection
                advancedSection
                groupSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .accessibilityIdentifier("host-form")
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存")) { save() }
                        .fontWeight(.semibold)
                        .disabled(viewModel.loadError != nil)
                        .accessibilityIdentifier("host-form.save")
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView(
                    host: viewModel.draft.toHost(existingID: viewModel.editingHostID),
                    username: viewModel.draft.username,
                    auth: viewModel.currentAuth(),
                    hops: diagnosticsHops,
                    proxyPassword: viewModel.currentProxyPassword,
                    transport: dependencies.diagnosticsTransport
                )
            }
            .sheet(item: $privateNetworkProfileEditorRequest) { request in
                PrivateNetworkProfileEditorView(
                    profileStore: dependencies.privateNetworkProfileRepository,
                    credentialStore: dependencies.credentialStore,
                    initialProfile: request.profile,
                    onSaved: { profile in
                        viewModel.draft.privateNetworkProfileID = profile.id
                        viewModel.reloadReferences()
                    }
                )
            }
            .alert(L("保存失败"), isPresented: Binding(
                get: { viewModel.saveError != nil },
                set: { if !$0 { viewModel.saveError = nil } }
            )) {
                Button(L("确定"), role: .cancel) { viewModel.saveError = nil }
            } message: {
                Text(viewModel.saveError ?? "")
            }
            .alert(L("读取主机配置失败"), isPresented: Binding(
                get: { viewModel.loadError != nil },
                set: { if !$0 { viewModel.loadError = nil } }
            )) {
                Button(L("重试")) { viewModel.reloadReferences() }
                Button(L("取消"), role: .cancel) { dismiss() }
            } message: {
                Text(viewModel.loadError ?? L("请稍后重试"))
            }
            .alert(L("连接测试失败"), isPresented: Binding(
                get: { diagnosticsError != nil },
                set: { if !$0 { diagnosticsError = nil } }
            )) {
                Button(L("确定"), role: .cancel) { diagnosticsError = nil }
            } message: {
                Text(diagnosticsError ?? "")
            }
        }
    }

    // MARK: - 区块

    private var pasteSection: some View {
        Section {
            Button {
                if let text = UIPasteboard.general.string {
                    viewModel.applyPaste(text)
                }
            } label: {
                Label(L("从剪贴板粘贴 ssh 命令"), systemImage: "doc.on.clipboard")
                    .foregroundStyle(.connAccent)
            }
            .listRowBackground(Color.connSurface)
        } footer: {
            Text(L("支持 ssh root@1.2.3.4 -p 2222 一类命令，自动识别地址、用户名与端口。"))
        }
    }

    /// 名称单列一组、置顶——它是这台机在列表里的「脸」，最该先填。
    private var identitySection: some View {
        Section {
            textRow(L("名称"), field: .name, text: $viewModel.draft.name, placeholder: L("便于记忆，选填"))
                .listRowBackground(Color.connSurface)
        } footer: {
            Text(L("留空时将显示主机地址。"))
        }
    }

    private var connectionSection: some View {
        Section(L("连接")) {
            textRow(
                L("地址"), field: .address, text: $viewModel.draft.address,
                placeholder: L("example.com 或 10.0.0.1"),
                error: viewModel.fieldErrors[.address], keyboard: .URL
            )
            portRow
            textRow(
                L("用户名"), field: .username, text: $viewModel.draft.username,
                placeholder: "root", error: viewModel.fieldErrors[.username]
            )
        }
        .listRowBackground(Color.connSurface)
    }

    private var authSection: some View {
        Section(L("认证")) {
            Picker(L("方式"), selection: $viewModel.draft.authKind) {
                Text(L("密码")).tag(Host.AuthKind.password)
                Text(L("密钥")).tag(Host.AuthKind.key)
            }
            .tint(.connMuted)
            switch viewModel.draft.authKind {
            case .password:
                secureRow(L("密码"), text: $viewModel.password)
            case .key:
                keyPicker
            }
        }
        .listRowBackground(Color.connSurface)
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                privateNetworkSettings
                privateNetworkManagementRow
                proxySettings
                jumpSettings
            } label: {
                Label(L("高级设置"), systemImage: "gearshape")
                    .foregroundStyle(.connInk)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("host-form.advanced")
            }
            .listRowBackground(Color.connSurface)
        }
    }

    private var privateNetworkSettings: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            Picker(L("私有网络"), selection: Binding(
                get: { viewModel.draft.privateNetworkProfileID ?? "" },
                set: {
                    viewModel.draft.privateNetworkProfileID = $0.isEmpty ? nil : $0
                    if !$0.isEmpty {
                        viewModel.draft.proxyConfiguration = nil
                        viewModel.proxyPassword = ""
                    }
                }
            )) {
                Text(L("普通网络直连")).tag("")
                ForEach(viewModel.availablePrivateNetworkProfiles) { profile in
                    Text("\(profile.name) · \(privateNetworkProviderName(profile.provider))")
                        .tag(profile.id)
                }
            }
            .tint(.connMuted)
            .accessibilityIdentifier("host-form.private-network")
            if let error = viewModel.fieldErrors[.privateNetwork] {
                Text(error).font(.connFootnote).foregroundStyle(.connCrit)
            }
            Text(L("仅当前主机使用嵌入式连接，不会启动系统 VPN；需要对应 Tailnet 的 auth key。"))
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
        }
        .padding(.vertical, ConnSpacing.xs)
    }

    private var privateNetworkManagementRow: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            Button {
                privateNetworkProfileEditorRequest = .init(profile: nil)
            } label: {
                Label(L("管理 Tailscale / Headscale 配置"), systemImage: "network")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .accessibilityIdentifier("host-form.private-network.manage")
            if let profileID = viewModel.draft.privateNetworkProfileID,
               let profile = viewModel.availablePrivateNetworkProfiles.first(where: { $0.id == profileID }) {
                Button {
                    privateNetworkProfileEditorRequest = .init(profile: profile)
                } label: {
                    Label(L("编辑当前配置"), systemImage: "pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .accessibilityIdentifier("host-form.private-network.edit")
            }
        }
        .padding(.vertical, ConnSpacing.xs)
    }

    private var proxySettings: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            Toggle(L("使用代理"), isOn: Binding(
                get: { viewModel.draft.proxyConfiguration != nil },
                set: { enabled in
                    if enabled {
                        viewModel.draft.privateNetworkProfileID = nil
                        if viewModel.draft.proxyConfiguration == nil {
                            viewModel.draft.proxyConfiguration = SSHProxyConfiguration()
                        }
                    } else {
                        viewModel.draft.proxyConfiguration = nil
                        viewModel.proxyPassword = ""
                    }
                }
            ))
            .tint(.connAccent)
            .accessibilityIdentifier("host-form.proxy-toggle")

            if viewModel.draft.proxyConfiguration != nil {
                Picker(L("类型"), selection: proxyBinding(\.kind, fallback: .httpConnect)) {
                    Text(L("HTTP CONNECT")).tag(SSHProxyConfiguration.Kind.httpConnect)
                    Text(L("SOCKS5")).tag(SSHProxyConfiguration.Kind.socks5)
                }
                .tint(.connMuted)
                .accessibilityIdentifier("host-form.proxy-kind")

                textRow(
                    L("代理 Host"), field: nil, text: proxyBinding(\.host, fallback: ""),
                    placeholder: L("proxy.example.com"),
                    keyboard: .URL,
                    identifier: "proxy-host"
                )
                proxyPortRow
                Picker(L("认证"), selection: proxyBinding(\.authentication, fallback: .none)) {
                    Text(L("无")).tag(SSHProxyConfiguration.Authentication.none)
                    Text(L("用户名/密码")).tag(SSHProxyConfiguration.Authentication.password)
                }
                .tint(.connMuted)
                .accessibilityIdentifier("host-form.proxy-authentication")
                if viewModel.draft.proxyConfiguration?.authentication == .password {
                    textRow(
                        L("用户名"), field: nil, text: proxyBinding(\.username, fallback: ""),
                        placeholder: L("代理用户名"), identifier: "proxy-username"
                    )
                    proxyPasswordRow
                }
                if let error = viewModel.fieldErrors[.proxy] {
                    Text(error).font(.connFootnote).foregroundStyle(.connCrit)
                }
                Text(L("通过 HTTP CONNECT 或 SOCKS5 代理隧道访问 SSH。"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
        }
        .padding(.vertical, ConnSpacing.xs)
    }

    private var jumpSettings: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.sm) {
            Toggle(L("使用跳板机"), isOn: Binding(
                get: { !viewModel.draft.jumpChain.isEmpty },
                set: { enabled in
                    if enabled {
                        if viewModel.draft.jumpChain.isEmpty,
                           let first = viewModel.availableJumpHosts.first {
                            viewModel.draft.jumpChain = [first.id]
                        }
                    } else {
                        viewModel.draft.jumpChain = []
                    }
                }
            ))
            .tint(.connAccent)
            .accessibilityIdentifier("host-form.jump-toggle")

            ForEach(Array(viewModel.draft.jumpChain.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: ConnSpacing.sm) {
                    Picker(L("跳板机"), selection: jumpBinding(at: index)) {
                        Text(L("请选择")).tag("")
                        ForEach(jumpOptions(for: index)) { host in
                            Text(host.displayAddress).tag(host.id)
                        }
                    }
                    .tint(.connMuted)
                    .accessibilityIdentifier("host-form.jump-host-\(index)")
                    Button {
                        viewModel.draft.jumpChain.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.connMuted)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("移除跳板机"))
                }
            }
            if viewModel.draft.jumpChain.count < viewModel.availableJumpHosts.count {
                Button {
                    if let next = jumpOptions(for: viewModel.draft.jumpChain.count).first {
                        viewModel.draft.jumpChain.append(next.id)
                    }
                } label: {
                    Label(L("添加跳板机"), systemImage: "plus")
                }
                .accessibilityIdentifier("host-form.jump-add")
            }
            if let error = viewModel.fieldErrors[.jumpChain] {
                Text(error).font(.connFootnote).foregroundStyle(.connCrit)
            }
            if viewModel.availableJumpHosts.isEmpty {
                hint(L("暂无可用跳板机，请先保存另一台主机。"))
            } else {
                Text(L("跳板机使用已保存主机的地址、端口和认证方式。"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
        }
        .padding(.vertical, ConnSpacing.xs)
    }

    private func privateNetworkProviderName(_ provider: PrivateNetworkProfile.Provider) -> String {
        switch provider {
        case .tailscale: L("Tailscale")
        case .headscale: L("Headscale")
        }
    }

    private func proxyBinding<Value>(
        _ keyPath: WritableKeyPath<SSHProxyConfiguration, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                viewModel.draft.proxyConfiguration.map { $0[keyPath: keyPath] } ?? fallback
            },
            set: { value in
                guard var proxy = viewModel.draft.proxyConfiguration else { return }
                proxy[keyPath: keyPath] = value
                viewModel.draft.proxyConfiguration = proxy
            }
        )
    }

    private var proxyPortRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: ConnSpacing.sm) {
                Text(L("代理端口"))
                    .foregroundStyle(.connMuted)
                    .frame(width: labelWidth, alignment: .leading)
                TextField("8080", value: proxyBinding(\.port, fallback: 8080), format: .number.grouping(.never))
                    .foregroundStyle(.connInk)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("host-form.proxy-port")
            }
        }
    }

    private var proxyPasswordRow: some View {
        HStack(spacing: ConnSpacing.sm) {
            Text(L("代理密码"))
                .foregroundStyle(.connMuted)
                .frame(width: labelWidth, alignment: .leading)
            Group {
                if isProxyPasswordVisible {
                    TextField(L("请输入代理密码"), text: $viewModel.proxyPassword)
                } else {
                    SecureField(L("请输入代理密码"), text: $viewModel.proxyPassword)
                }
            }
            .foregroundStyle(.connInk)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .accessibilityIdentifier("host-form.proxy-password")

            Button {
                isProxyPasswordVisible.toggle()
            } label: {
                Image(systemName: isProxyPasswordVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.connMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isProxyPasswordVisible ? L("隐藏密码") : L("显示密码"))
        }
    }

    private func jumpBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard viewModel.draft.jumpChain.indices.contains(index) else { return "" }
                return viewModel.draft.jumpChain[index]
            },
            set: { value in
                guard viewModel.draft.jumpChain.indices.contains(index) else { return }
                viewModel.draft.jumpChain[index] = value
            }
        )
    }

    private func jumpOptions(for index: Int) -> [Host] {
        let currentID = viewModel.draft.jumpChain.indices.contains(index)
            ? viewModel.draft.jumpChain[index]
            : nil
        let selectedIDs = Set(viewModel.draft.jumpChain)
        return viewModel.availableJumpHosts.filter { host in
            host.id == currentID || !selectedIDs.contains(host.id)
        }
    }

    private var keyPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L("SSH 密钥"), selection: Binding(
                get: { viewModel.draft.keyUUID ?? "" },
                set: { viewModel.draft.keyUUID = $0.isEmpty ? nil : $0 }
            )) {
                Text(L("请选择密钥")).tag("")
                ForEach(viewModel.availableKeys) { key in
                    Text("\(key.name) · \(key.kind.displayName)").tag(key.id)
                }
            }
            .tint(.connMuted)
            if let error = viewModel.fieldErrors[.key] {
                Text(error).font(.connFootnote).foregroundStyle(.connCrit)
            }
            if viewModel.availableKeys.isEmpty {
                hint(L("暂无密钥，请先在“密钥管理”中生成或导入密钥。"))
            }
        }
    }

    @ViewBuilder
    private var groupSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isGroupExpanded) {
                if viewModel.availableGroups.isEmpty {
                    Text(L("暂无分组，请使用右上角“+”创建分组。"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                } else {
                    ForEach(viewModel.availableGroups) { group in
                        Button {
                            toggleGroup(group.id)
                        } label: {
                            HStack {
                                Text(group.name)
                                    .foregroundStyle(.connInk)
                                Spacer()
                                Image(systemName: viewModel.draft.groupIDs.contains(group.id)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(viewModel.draft.groupIDs.contains(group.id)
                                        ? Color.connAccent
                                        : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text(L("可多选，也可以不选；不选时归为未分组。"))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
            } label: {
                HStack {
                    Text(L("分组"))
                    Spacer()
                    Text(groupSelectionSummary)
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
            }
            .listRowBackground(Color.connSurface)
        }
    }

    private var groupSelectionSummary: String {
        if viewModel.availableGroups.isEmpty { return L("暂无") }
        if viewModel.draft.groupIDs.isEmpty { return L("未分组") }
        return String(format: L("已选 %d 个"), viewModel.draft.groupIDs.count)
    }

    private func toggleGroup(_ groupID: String) {
        if let index = viewModel.draft.groupIDs.firstIndex(of: groupID) {
            viewModel.draft.groupIDs.remove(at: index)
        } else {
            viewModel.draft.groupIDs.append(groupID)
        }
    }

    private var testSection: some View {
        Section {
            Button {
                beginDiagnostics()
            } label: {
                Label(L("连接测试"), systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(viewModel.draft.isValid ? Color.connAccent : .connMuted)
            }
            .disabled(!viewModel.draft.isValid || !viewModel.canTestConnection)
            .listRowBackground(Color.connSurface)
        }
    }

    private func beginDiagnostics() {
        do {
            diagnosticsHops = try viewModel.currentJumpHops()
            showDiagnostics = true
        } catch {
            diagnosticsError = error.friendlyDiagnosis
        }
    }

    // MARK: - 行

    /// 左字段名（固定列宽）+ 右输入。错误信息在行下方以红字提示。
    private func textRow(
        _ label: String,
        field: HostDraft.Field?,
        text: Binding<String>,
        placeholder: String,
        error: String? = nil,
        keyboard: UIKeyboardType = .default,
        identifier: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: ConnSpacing.sm) {
                Text(label)
                    .foregroundStyle(.connMuted)
                    .frame(width: labelWidth, alignment: .leading)
                TextField(placeholder, text: text)
                    .foregroundStyle(.connInk)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: field)
                    .accessibilityIdentifier("host-form.\(identifier ?? fieldIdentifier(field))")
            }
            if let error {
                Text(error)
                    .font(.connFootnote)
                    .foregroundStyle(.connCrit)
                    .padding(.leading, labelWidth + ConnSpacing.sm)
            }
        }
    }

    private var portRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: ConnSpacing.sm) {
                Text(L("端口"))
                    .foregroundStyle(.connMuted)
                    .frame(width: labelWidth, alignment: .leading)
                TextField("22", value: $viewModel.draft.port, format: .number.grouping(.never))
                    .foregroundStyle(.connInk)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .port)
            }
            if let portError = viewModel.fieldErrors[.port] {
                Text(portError)
                    .font(.connFootnote)
                    .foregroundStyle(.connCrit)
                    .padding(.leading, labelWidth + ConnSpacing.sm)
            }
        }
    }

    private func secureRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Text(label)
                .foregroundStyle(.connMuted)
                .frame(width: labelWidth, alignment: .leading)
            Group {
                if isPasswordVisible {
                    TextField(L("选填"), text: text)
                } else {
                    SecureField(L("选填"), text: text)
                }
            }
            .foregroundStyle(.connInk)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)

            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.connMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPasswordVisible ? L("隐藏密码") : L("显示密码"))
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.connFootnote)
            .foregroundStyle(.connMuted)
    }

    private func fieldIdentifier(_ field: HostDraft.Field?) -> String {
        switch field {
        case .name: "name"
        case .address: "address"
        case .port: "port"
        case .username: "username"
        case .key: "key"
        case .privateNetwork: "private-network"
        case .proxy: "proxy"
        case .jumpChain: "jump-chain"
        case nil: "field"
        }
    }

    private func save() {
        if let result = viewModel.save() {
            // Keep the save result on the main-actor call stack. The old
            // unstructured async callback outlived the sheet and could copy
            // Host across the SwiftUI closure boundary during dismissal.
            onSaved(result)
            dismiss()
        }
    }
}
