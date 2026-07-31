import ConnOps
import ConnUI
import SwiftUI

struct DockerVolumeFormState {
    var name = ""
    var driver = "local"
    var otherOptions: [DockerTokenRow] = []

    var draft: DockerVolumeDraft {
        DockerVolumeDraft(name: name, driver: driver, otherOptionTokens: otherOptions.map(\.value))
    }

    var isValid: Bool { draft.validate().isEmpty }
}

struct DockerNetworkFormState {
    var name = ""
    var driver = "bridge"
    var isInternal = false
    var isAttachable = false
    var otherOptions: [DockerTokenRow] = []

    var draft: DockerNetworkDraft {
        DockerNetworkDraft(
            name: name, driver: driver, isInternal: isInternal, isAttachable: isAttachable,
            otherOptionTokens: otherOptions.map(\.value)
        )
    }

    var isValid: Bool { draft.validate().isEmpty }
}

/// 卷创建表单只编辑不可变 `DockerVolumeDraft` 的本地映射，提交时把草稿交给 Operations。
struct DockerVolumeFormView: View {
    let operations: DockerOperationsModel
    @Environment(\.dismiss) private var dismiss
    @State private var state = DockerVolumeFormState()

    var body: some View {
        NavigationStack {
            Form {
                Section(L("基本")) {
                    TextField(L("名称"), text: $state.name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("驱动"), text: $state.driver).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .listRowBackground(Color.connSurface)
                tokenSection(rows: $state.otherOptions)
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("创建卷"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("创建")) {
                        Task {
                            await operations.createVolume(state.draft)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!state.isValid || !operations.isWriteAvailable)
                }
            }
        }
    }
}

/// 网络创建表单与卷共用逐 token 编辑器，但保留 internal / attachable 两个结构化 flag。
struct DockerNetworkFormView: View {
    let operations: DockerOperationsModel
    @Environment(\.dismiss) private var dismiss
    @State private var state = DockerNetworkFormState()

    var body: some View {
        NavigationStack {
            Form {
                Section(L("基本")) {
                    TextField(L("名称"), text: $state.name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("驱动"), text: $state.driver).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle(L("内部网络"), isOn: $state.isInternal)
                    Toggle(L("可附加"), isOn: $state.isAttachable)
                }
                .listRowBackground(Color.connSurface)
                tokenSection(rows: $state.otherOptions)
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("创建网络"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("创建")) {
                        Task {
                            await operations.createNetwork(state.draft)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!state.isValid || !operations.isWriteAvailable)
                }
            }
        }
    }
}

@ViewBuilder
private func tokenSection(rows: Binding<[DockerTokenRow]>) -> some View {
    Section(L("高级选项")) {
        ForEach(rows) { $token in
            TextField(L("选项"), text: $token.value).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .onDelete { offsets in
            rows.wrappedValue.remove(atOffsets: offsets)
        }
        Button { rows.wrappedValue.append(DockerTokenRow()) } label: { Label(L("添加选项"), systemImage: "plus") }
    }
    .listRowBackground(Color.connSurface)
}
