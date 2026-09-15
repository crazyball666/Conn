import ConnKit
import ConnUI
import SwiftUI

struct HostJumpConnectionView: View {
    @Bindable var viewModel: HostFormViewModel
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Form {
            Section {
                ForEach(Array(viewModel.draft.jumpChain.enumerated()), id: \.element) { index, id in
                    HStack(spacing: ConnSpacing.md) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.connMuted)
                            .accessibilityLabel(String(format: L("第 %d 跳"), index + 1))
                        VStack(alignment: .leading, spacing: 4) {
                            if let host = viewModel.availableJumpHosts.first(where: { $0.id == id }) {
                                Text(host.name.isEmpty ? host.address : host.name).foregroundStyle(.connInk)
                                Text(host.displayAddress).font(.connFootnote).foregroundStyle(.connMuted)
                            } else {
                                Text(L("主机不可用")).foregroundStyle(.connCrit)
                            }
                        }
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            viewModel.draft.jumpChain.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("移除跳板机"))
                        .accessibilityIdentifier("jump-route.remove.\(index)")
                    }
                }
                .onMove { offsets, destination in
                    viewModel.draft.jumpChain.move(fromOffsets: offsets, toOffset: destination)
                }
                NavigationLink {
                    HostJumpHostPicker(viewModel: viewModel)
                } label: {
                    Label(
                        viewModel.draft.jumpChain.isEmpty ? L("选择跳板机") : L("添加下一跳"),
                        systemImage: "plus"
                    )
                    .foregroundStyle(.connAccent)
                }
                .accessibilityIdentifier("host-form.jump-add")
                .disabled(viewModel.availableJumpHosts.allSatisfy { viewModel.draft.jumpChain.contains($0.id) })
            } header: {
                Text(L("连接顺序"))
            } footer: {
                Text(L("按列表顺序经过跳板机，最后连接目标主机。使用各跳板机已保存的 SSH 认证。"))
            }
            .listRowBackground(Color.connSurface)
            if viewModel.availableJumpHosts.isEmpty {
                Section { Text(L("暂无可用跳板机，请先保存另一台主机。")).foregroundStyle(.connMuted) }
                    .listRowBackground(Color.connSurface)
            }
            if let error = viewModel.fieldErrors[.jumpChain] {
                Section { Text(error).font(.connFootnote).foregroundStyle(.connCrit) }
                    .listRowBackground(Color.connSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("跳板机"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("jump-route.form")
        .environment(\.editMode, $editMode)
        .onChange(of: viewModel.draft.jumpChain.count) { _, count in
            if count < 2 { editMode = .inactive }
        }
        .toolbar {
            if viewModel.draft.jumpChain.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    EditButton().accessibilityIdentifier("jump-route.reorder")
                }
            }
        }
    }
}

private struct HostJumpHostPicker: View {
    @Bindable var viewModel: HostFormViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(viewModel.availableJumpHosts.filter { !viewModel.draft.jumpChain.contains($0.id) }) { host in
                Button {
                    guard !viewModel.draft.jumpChain.contains(host.id) else { return }
                    viewModel.draft.jumpChain.append(host.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.name.isEmpty ? host.address : host.name).foregroundStyle(.connInk)
                        Text(host.displayAddress).font(.connFootnote).foregroundStyle(.connMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("jump-route.select.\(host.id)")
                .listRowBackground(Color.connSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("选择跳板机"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("jump-route.picker")
    }
}
