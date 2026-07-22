import ConnKit
import ConnUI
import SwiftUI

/// 密钥管家（原型 S9）。
struct KeyManagerView: View {
    @State private var viewModel: KeyManagerViewModel
    @State private var showGenerate = false
    @State private var newKeyName = ""

    init(dependencies: AppDependencies) {
        _viewModel = State(initialValue: KeyManagerViewModel(
            keyStore: dependencies.keyRepository,
            credentialStore: dependencies.credentialStore
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
        .navigationTitle("密钥管家")
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.load() }
        .alert("生成 Ed25519 密钥", isPresented: $showGenerate) {
            TextField("密钥名称", text: $newKeyName)
            Button("生成") {
                viewModel.generateEd25519(name: newKeyName)
                newKeyName = ""
            }
            Button("取消", role: .cancel) { newKeyName = "" }
        } message: {
            Text("Ed25519 在所有现代与旧版服务器上都可用，是推荐的默认密钥类型。")
        }
    }

    private var header: some View {
        HStack {
            Text("密钥")
                .font(.connSectionTitle)
                .foregroundStyle(.connInk)
            Spacer()
            IconChipButton("plus", tint: .accent, accessibilityLabel: "生成密钥") {
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
                    Button("复制公钥") {
                        UIPasteboard.general.string = viewModel.publicKey(for: key)
                    }
                    Button("删除", role: .destructive) { viewModel.delete(key) }
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
            title: "还没有密钥",
            message: "生成一把 Ed25519 密钥，部署到主机后即可免密登录",
            primary: .init("生成 Ed25519 密钥") { showGenerate = true }
        )
        .padding(.top, ConnSpacing.xxl)
    }
}
