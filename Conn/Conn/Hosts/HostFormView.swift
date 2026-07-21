import ConnKit
import ConnUI
import SwiftUI

/// 主机新增/编辑表单（原型未出稿，按 PRD §5.1 实现：只必填地址+用户名+认证）。
struct HostFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: HostFormViewModel
    @State private var showDiagnostics = false
    private let dependencies: AppDependencies
    private let onSaved: () -> Void

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
                requiredSection
                authSection
                advancedSection
                testSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.fontWeight(.semibold)
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
                    let recognized = viewModel.applyPaste(text)
                    if !recognized { /* 非 ssh 文本，静默忽略 */ }
                }
            } label: {
                Label("从剪贴板粘贴 ssh 命令", systemImage: "doc.on.clipboard")
                    .foregroundStyle(.connAccent)
            }
        } footer: {
            Text("支持 ssh root@1.2.3.4 -p 2222 一类命令，自动识别地址、用户名与端口。")
        }
    }

    private var requiredSection: some View {
        Section("必填") {
            labeledField(
                "地址",
                text: $viewModel.draft.address,
                error: viewModel.fieldErrors[.address],
                placeholder: "example.com 或 10.0.0.1"
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            labeledField("用户名", text: $viewModel.draft.username, error: viewModel.fieldErrors[.username], placeholder: "root")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var authSection: some View {
        Section("认证") {
            Picker("方式", selection: $viewModel.draft.authKind) {
                Text("密码").tag(Host.AuthKind.password)
                Text("密钥").tag(Host.AuthKind.key)
                Text("密钥 + 密码短语").tag(Host.AuthKind.keyPassphrase)
            }
            switch viewModel.draft.authKind {
            case .password:
                SecureField("密码", text: $viewModel.password)
            case .keyPassphrase:
                SecureField("密码短语", text: $viewModel.passphrase)
                Text("密钥选择将在密钥管家上线后支持").font(.connFootnote).foregroundStyle(.connMuted)
            case .key:
                Text("密钥选择将在密钥管家上线后支持").font(.connFootnote).foregroundStyle(.connMuted)
            case .agent:
                Text("SSH Agent 转发").font(.connFootnote).foregroundStyle(.connMuted)
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级选项", isExpanded: $viewModel.showAdvanced) {
                HStack {
                    Text("端口")
                    Spacer()
                    TextField("22", value: $viewModel.draft.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                if let portError = viewModel.fieldErrors[.port] {
                    Text(portError).font(.connFootnote).foregroundStyle(.connCrit)
                }
                labeledField("名称（留空用地址）", text: $viewModel.draft.name, error: nil, placeholder: viewModel.draft.address)
                labeledField("备注", text: Binding(
                    get: { viewModel.draft.note ?? "" },
                    set: { viewModel.draft.note = $0.isEmpty ? nil : $0 }
                ), error: nil, placeholder: "可选")
            }
        }
    }

    private var testSection: some View {
        Section {
            Button {
                showDiagnostics = true
            } label: {
                Label("连接测试", systemImage: "bolt.horizontal.circle")
            }
            .disabled(!viewModel.draft.isValid)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, error: String?, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: text)
            if let error {
                Text(error).font(.connFootnote).foregroundStyle(.connCrit)
            }
        }
    }

    private func save() {
        if viewModel.save() != nil {
            onSaved()
            dismiss()
        }
    }
}
