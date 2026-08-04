import ConnKit
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
    @State private var isGroupExpanded = false
    @State private var isPasswordVisible = false
    @FocusState private var focus: HostDraft.Field?
    private let dependencies: AppDependencies
    private let onSaved: (HostFormSaveResult) async -> Void

    /// 字段名列宽：容纳「用户名 / 认证方式」等最长 4 个汉字，全表左对齐。
    private let labelWidth: CGFloat = 76

    init(
        dependencies: AppDependencies,
        initialDraft: HostDraft,
        editingHostID: String?,
        onSaved: @escaping (HostFormSaveResult) async -> Void
    ) {
        self.dependencies = dependencies
        self.onSaved = onSaved
        _viewModel = State(initialValue: HostFormViewModel(
            draft: initialDraft,
            editingHostID: editingHostID,
            hostStore: dependencies.hostRepository,
            credentialStore: dependencies.credentialStore,
            groupStore: dependencies.hostGroupRepository,
            keyStore: dependencies.keyRepository
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                pasteSection
                identitySection
                connectionSection
                authSection
                groupSection
                noteSection
                testSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
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
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView(
                    host: viewModel.draft.toHost(existingID: viewModel.editingHostID),
                    username: viewModel.draft.username,
                    auth: viewModel.currentAuth(),
                    transport: dependencies.diagnosticsTransport
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
            Text(L("留空则用地址显示。"))
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
                hint(L("还没有密钥，请先在密钥管家中生成或导入"))
            }
        }
    }

    @ViewBuilder
    private var groupSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isGroupExpanded) {
                if viewModel.availableGroups.isEmpty {
                    Text(L("还没有分组，先用右上角「+」新建。"))
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

    private var noteSection: some View {
        Section {
            textRow(L("备注"), field: nil, text: Binding(
                get: { viewModel.draft.note ?? "" },
                set: { viewModel.draft.note = $0.isEmpty ? nil : $0 }
            ), placeholder: L("选填"))
                .listRowBackground(Color.connSurface)
        }
    }

    private var testSection: some View {
        Section {
            Button {
                showDiagnostics = true
            } label: {
                Label(L("连接测试"), systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(viewModel.draft.isValid ? Color.connAccent : .connMuted)
            }
            .disabled(!viewModel.draft.isValid || !viewModel.canTestConnection)
            .listRowBackground(Color.connSurface)
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
        keyboard: UIKeyboardType = .default
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

    private func save() {
        if let result = viewModel.save() {
            Task {
                await onSaved(result)
                dismiss()
            }
        }
    }
}
