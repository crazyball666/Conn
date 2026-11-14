import ConnOps
import ConnUI
import SwiftUI

/// Git Stash 列表与常用操作。
struct GitStashSheet: View {
    @Bindable var viewModel: GitWorkspaceViewModel
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L("新建 Stash")) {
                    TextField(L("Stash 信息（可选）"), text: $message, axis: .vertical)
                        .lineLimit(1...3)
                    Button {
                        let text = message
                        message = ""
                        Task { await viewModel.createStash(message: text) }
                    } label: {
                        Label(L("创建 Stash"), systemImage: "archivebox")
                    }
                    .disabled(viewModel.isBusy)
                }

                Section(L("Stashes")) {
                    if viewModel.stashes.isEmpty {
                        Text(L("暂无 Stash"))
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                    } else {
                        ForEach(viewModel.stashes) { stash in
                            Menu {
                                Button {
                                    Task { await viewModel.applyStash(stash) }
                                } label: {
                                    Label(L("应用"), systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    Task { await viewModel.popStash(stash) }
                                } label: {
                                    Label(L("弹出"), systemImage: "arrow.up.square")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    Task { await viewModel.dropStash(stash) }
                                } label: {
                                    Label(L("删除"), systemImage: "trash")
                                }
                            } label: {
                                HStack(spacing: ConnSpacing.sm) {
                                    Image(systemName: "archivebox")
                                        .foregroundStyle(.connAccent)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(stash.index)
                                            .font(.connData(.caption2))
                                            .foregroundStyle(.connMuted)
                                        Text(stash.message.isEmpty ? L("Stash") : stash.message)
                                            .font(.connSubheadline)
                                            .foregroundStyle(.connInk)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Image(systemName: "ellipsis")
                                        .foregroundStyle(.connDim)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Stash"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }
                }
            }
            .refreshable { await viewModel.refresh() }
        }
    }
}
