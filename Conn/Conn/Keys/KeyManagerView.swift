import ConnKit
import ConnUI
import SwiftUI

/// 密钥管家（原型 S9）。
struct KeyManagerView: View {
    @State private var viewModel: KeyManagerViewModel
    @State private var showGenerate = false
    @State private var newKeyName = ""
    @State private var pendingDelete: SSHKey?

    init(dependencies: AppDependencies) {
        _viewModel = State(initialValue: KeyManagerViewModel(
            keyStore: dependencies.keyRepository,
            credentialStore: dependencies.credentialStore,
            hostStore: dependencies.hostRepository
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if viewModel.keys.isEmpty {
                    emptyState
                } else {
                    keyList
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("密钥管家"))
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.load() }
        .alert(L("生成 Ed25519 密钥"), isPresented: $showGenerate) {
            TextField(L("密钥名称"), text: $newKeyName)
            Button(L("生成")) {
                viewModel.generateEd25519(name: newKeyName)
                newKeyName = ""
            }
            Button(L("取消"), role: .cancel) { newKeyName = "" }
        } message: {
            Text(L("Ed25519 在所有现代与旧版服务器上都可用，是推荐的默认密钥类型。"))
        }
        .alert(
            L("删除密钥"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { key in
            Button(L("删除"), role: .destructive) {
                viewModel.delete(key)
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { key in
            // 删除会经外键把这些主机的 key_uuid 置空，必须先告知台数。
            let count = viewModel.hostCount(using: key)
            if count > 0 {
                Text(String(
                    format: L("%d 台主机正在使用此密钥，删除后这些主机需要重新选择认证方式。"),
                    count
                ))
            } else {
                Text(L("密钥将被永久删除，无法恢复。"))
            }
        }
    }

    private var header: some View {
        HStack {
            Text(L("密钥"))
                .font(.connSectionTitle)
                .foregroundStyle(.connInk)
            Spacer()
            IconChipButton("plus", tint: .accent, accessibilityLabel: L("生成密钥")) {
                showGenerate = true
            }
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.vertical, ConnSpacing.sm)
    }

    private var keyList: some View {
        LazyVStack(spacing: ConnSpacing.stackGap) {
            ForEach(viewModel.keys) { key in
                ConnListRow(
                    title: key.name,
                    subtitle: key.publicKey.count > 40 ? String(key.publicKey.prefix(40)) + "…" : key.publicKey,
                    tags: keyTags(key),
                    leading: { IconChip("key.fill", tint: .accent) },
                    trailing: { EmptyView() }
                )
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
        var tags = [ConnRowTag(key.kind.opensshPrefix.replacingOccurrences(of: "ssh-", with: ""), kind: .info)]
        if key.isSecureEnclave {
            tags.append(ConnRowTag("Secure Enclave", kind: .accent))
        }
        return tags
    }

    private var emptyState: some View {
        EmptyState(
            systemName: "key",
            title: L("还没有密钥"),
            message: L("生成一把 Ed25519 密钥，部署到主机后即可免密登录"),
            primary: .init(L("生成 Ed25519 密钥")) { showGenerate = true }
        )
        .padding(.top, ConnSpacing.xxl)
    }
}
