import ConnKit
import ConnSSH
import ConnUI
import SwiftUI
import UniformTypeIdentifiers

/// 密钥管家（原型 S9）。
struct KeyManagerView: View {
    @State private var viewModel: KeyManagerViewModel
    @State private var showGenerate = false
    @State private var newKeyName = ""
    @State private var generateKind: SSHKey.Kind = .ed25519
    @State private var showImport = false
    @State private var importKind: SSHKey.Kind = .ed25519
    @State private var importName = ""
    @State private var importText = ""
    @State private var showFileImporter = false
    @State private var pendingDelete: SSHKey?

    init(dependencies: AppDependencies) {
        _viewModel = State(initialValue: KeyManagerViewModel(
            keyStore: dependencies.keyRepository,
            credentialStore: dependencies.credentialStore,
            hostStore: dependencies.hostRepository
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.keys.isEmpty {
                        emptyState
                            .frame(
                                maxWidth: .infinity,
                                minHeight: max(0, geometry.size.height - ConnSpacing.page * 2),
                                alignment: .center
                            )
                    } else {
                        keyList
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("密钥管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showGenerate = true } label: {
                        Label(L("生成密钥"), systemImage: "plus")
                    }
                    Button { showImport = true } label: {
                        Label(L("导入私钥"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("新增密钥"))
            }
        }
        .task { viewModel.load() }
        .sheet(isPresented: $showGenerate) { generateSheet }
        .sheet(isPresented: $showImport) { importSheet }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.text, .data]) { result in
            if case let .success(url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    importText = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    viewModel.lastError = "\(L("私钥读取失败"))：\(error.friendlyDiagnosis)"
                }
            }
        }
        .alert(L("操作失败"), isPresented: Binding(
            get: { viewModel.lastError != nil },
            set: { if !$0 { viewModel.lastError = nil } }
        )) {
            Button(L("确定"), role: .cancel) { viewModel.lastError = nil }
        } message: {
            Text(viewModel.lastError ?? "")
        }
        .alert(
            L("删除密钥"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { key in
            Button(L("删除"), role: .destructive) {
                _ = viewModel.delete(key)
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { key in
            KeyDeletionMessage(hostCount: viewModel.hostCount(using: key))
        }
    }

    private var keyList: some View {
        LazyVStack(spacing: ConnSpacing.stackGap) {
            ForEach(viewModel.keys) { key in
                NavigationLink {
                    KeyDetailView(key: key, viewModel: viewModel)
                } label: {
                    ConnListRow(
                        title: key.name,
                        subtitle: key.publicKey.count > 56 ? String(key.publicKey.prefix(56)) + "…" : key.publicKey,
                        tags: keyTags(key),
                        leading: { IconChip("key.fill", tint: .accent) },
                        trailing: { Image(systemName: "chevron.right").foregroundStyle(.connMuted) }
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L("复制公钥")) {
                        UIPasteboard.general.string = viewModel.publicKey(for: key)
                    }
                    Button(L("删除"), role: .destructive) { pendingDelete = key }
                }
                .padding(.horizontal, ConnSpacing.page)
            }
        }
        .padding(.bottom, ConnSpacing.lg)
    }

    private func keyTags(_ key: SSHKey) -> [ConnRowTag] {
        [ConnRowTag(key.kind.displayName, kind: .info)]
    }

    private var emptyState: some View {
        EmptyState(
            systemName: "key",
            title: L("暂无密钥"),
            message: L("生成 Ed25519 密钥并部署到主机，即可使用密钥认证。"),
            primary: .init(L("生成密钥")) { showGenerate = true }
        )
    }

    private var generateSheet: some View {
        NavigationStack {
            Form {
                Section(L("密钥信息")) {
                    TextField(L("密钥名称"), text: $newKeyName)
                    Picker(L("算法"), selection: $generateKind) {
                        ForEach(SSHKey.Kind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                Section {
                    Text(L("密钥只保存在本地 Keychain"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L("生成密钥"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { showGenerate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("生成")) {
                        _ = viewModel.generate(kind: generateKind, name: newKeyName)
                        newKeyName = ""
                        showGenerate = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                Section(L("私钥信息")) {
                    TextField(L("密钥名称"), text: $importName)
                    Picker(L("算法"), selection: $importKind) {
                        ForEach(SSHKey.Kind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                Section(L("私钥内容")) {
                    TextEditor(text: $importText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 180)
                    Button(L("从文件选择")) { showFileImporter = true }
                }
                Text(L("仅支持未加密私钥。Ed25519、RSA 4096、ECDSA P-256 均支持 OpenSSH；RSA 也支持 PKCS#1/PKCS#8，ECDSA 支持 PEM/PKCS#8；Ed25519 和 ECDSA 也可粘贴原始私钥 Base64。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(L("导入私钥"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { showImport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("导入")) {
                        _ = viewModel.importPrivateKey(name: importName, kind: importKind, text: importText)
                        importText = ""
                        importName = ""
                        showImport = false
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct KeyDetailView: View {
    let key: SSHKey
    let viewModel: KeyManagerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.connToastCenter) private var toastCenter
    @State private var displayName: String
    @State private var renameName = ""
    @State private var isRenamePresented = false
    @State private var isDeletePresented = false
    @State private var privateMaterial: String?

    init(key: SSHKey, viewModel: KeyManagerViewModel) {
        self.key = key
        self.viewModel = viewModel
        _displayName = State(initialValue: key.name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                ConnCard {
                    VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                        Label(key.kind.displayName, systemImage: "key.fill")
                            .font(.connSectionTitle)
                            .foregroundStyle(.connAccent)
                        Text(key.publicKey)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.connMuted)
                    }
                }
                ConnCard {
                    VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                        Text(L("公钥"))
                            .font(.connSectionTitle)
                        Text(key.publicKey)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button(L("复制公钥")) { UIPasteboard.general.string = key.publicKey }
                            ShareLink(item: key.publicKey) { Label(L("导出"), systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                ConnCard {
                    VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                        Label(L("私钥"), systemImage: "lock.fill")
                            .font(.connSectionTitle)
                        if let privateMaterial {
                            Text(privateMaterial)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(8)
                                .textSelection(.enabled)
                            HStack {
                                Button(L("复制私钥")) { UIPasteboard.general.string = privateMaterial }
                                ShareLink(item: privateMaterial) {
                                    Label(L("导出私钥"), systemImage: "square.and.arrow.up")
                                }
                            }
                        } else {
                            Button(L("查看私钥")) {
                                privateMaterial = viewModel.privateMaterial(for: key)
                            }
                            .foregroundStyle(.connAccent)
                        }
                        Text(L("私钥仅保存在 Keychain；导出前请确认周围环境安全。"))
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                    }
                }
            }
            .padding(ConnSpacing.page)
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    renameName = displayName
                    isRenamePresented = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel(L("重命名"))
                .alert(L("重命名"), isPresented: $isRenamePresented) {
                    TextField(L("密钥名称"), text: $renameName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(L("保存")) {
                        let trimmed = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if viewModel.rename(key, to: trimmed) {
                            displayName = trimmed
                        }
                    }
                    .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L("取消"), role: .cancel) {}
                }

                Button(role: .destructive) {
                    isDeletePresented = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(L("删除密钥"))
                .accessibilityIdentifier("key.delete")
                .alert(L("删除密钥"), isPresented: $isDeletePresented) {
                    Button(L("删除"), role: .destructive) {
                        if viewModel.delete(key) {
                            dismiss()
                        } else {
                            toastCenter.show(viewModel.lastError, style: .error)
                            viewModel.lastError = nil
                        }
                    }
                    Button(L("取消"), role: .cancel) {}
                } message: {
                    KeyDeletionMessage(hostCount: viewModel.hostCount(using: key))
                }
            }
        }
    }
}

private struct KeyDeletionMessage: View {
    let hostCount: Int

    var body: some View {
        if hostCount > 0 {
            Text(String(
                format: L("%d 台主机正在使用此密钥，删除后这些主机需要重新选择认证方式。"),
                hostCount
            ))
        } else {
            Text(L("密钥将被永久删除，无法恢复。"))
        }
    }
}
