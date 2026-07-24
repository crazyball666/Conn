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
    @FocusState private var focus: HostDraft.Field?
    private let dependencies: AppDependencies
    private let onSaved: () -> Void

    /// 字段名列宽：容纳「用户名 / 密码短语」等最长 4 个汉字，全表左对齐。
    private let labelWidth: CGFloat = 76

    init(
        dependencies: AppDependencies,
        initialDraft: HostDraft,
        editingHostID: String?,
        onSaved: @escaping () -> Void
    ) {
        self.dependencies = dependencies
        self.onSaved = onSaved
        _viewModel = State(initialValue: HostFormViewModel(
            draft: initialDraft,
            editingHostID: editingHostID,
            hostStore: dependencies.hostRepository,
            credentialStore: dependencies.credentialStore
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                pasteSection
                identitySection
                connectionSection
                authSection
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
                    Button(L("保存")) { save() }.fontWeight(.semibold)
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
                Text(L("密钥 + 密码短语")).tag(Host.AuthKind.keyPassphrase)
            }
            .tint(.connMuted)
            switch viewModel.draft.authKind {
            case .password:
                secureRow(L("密码"), text: $viewModel.password)
            case .keyPassphrase:
                secureRow(L("密码短语"), text: $viewModel.passphrase)
                hint(L("密钥选择将在密钥管家上线后支持"))
            case .key:
                hint(L("密钥选择将在密钥管家上线后支持"))
            case .agent:
                hint(L("SSH Agent 转发"))
            }
        }
        .listRowBackground(Color.connSurface)
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
            .disabled(!viewModel.draft.isValid)
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
            SecureField(L("选填"), text: text)
                .foregroundStyle(.connInk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.connFootnote)
            .foregroundStyle(.connMuted)
    }

    private func save() {
        if viewModel.save() != nil {
            onSaved()
            dismiss()
        }
    }
}
