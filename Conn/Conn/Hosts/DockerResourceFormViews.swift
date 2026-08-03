import ConnOps
import ConnUI
import SwiftUI

/// 多行高级参数转成 Docker 命令的 argv。每行保留为一个参数，便于直接粘贴
/// `--flag=value`；空行和注释行不参与预览或执行。
private func parseDockerOptionText(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// 保存回调只有在命令真正落库成功后才返回，表单据此锁定按钮，避免重复保存。
typealias DockerCommandSaveHandler = (String, String) throws -> Void

enum DockerCommandSaveError: Error {
    case unavailable
}

struct DockerVolumeFormState {
    var name = ""
    var driver = "local"
    var otherOptionsText = ""

    var draft: DockerVolumeDraft {
        DockerVolumeDraft(
            name: name,
            driver: driver,
            otherOptionTokens: parseDockerOptionText(otherOptionsText)
        )
    }

    var isValid: Bool { draft.validate().isEmpty }
}

struct DockerNetworkFormState {
    var name = ""
    var driver = "bridge"
    var isInternal = false
    var isAttachable = false
    var otherOptionsText = ""

    var draft: DockerNetworkDraft {
        DockerNetworkDraft(
            name: name, driver: driver, isInternal: isInternal, isAttachable: isAttachable,
            otherOptionTokens: parseDockerOptionText(otherOptionsText)
        )
    }

    var isValid: Bool { draft.validate().isEmpty }
}

/// 卷创建表单：基本配置 → 高级文本参数 → 命令预览，与容器创建保持同一信息结构。
struct DockerVolumeFormView: View {
    let operations: DockerOperationsModel
    let onSaveAsCommand: DockerCommandSaveHandler?
    @Environment(\.dismiss) private var dismiss
    @State private var state = DockerVolumeFormState()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var savedTitle: String?
    @State private var isCommandSaved = false

    init(
        operations: DockerOperationsModel,
        onSaveAsCommand: DockerCommandSaveHandler? = nil
    ) {
        self.operations = operations
        self.onSaveAsCommand = onSaveAsCommand
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("基本")) {
                    TextField(L("名称"), text: $state.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("驱动"), text: $state.driver)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .listRowBackground(Color.connSurface)
                advancedSection
                previewSection
                errorSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("创建卷"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L("创建"))
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!state.isValid || !operations.isWriteAvailable || isSubmitting)
                }
            }
        }
    }

    private var advancedSection: some View {
        Section {
            TextEditor(text: $state.otherOptionsText)
                .font(.connData(.footnote))
                .frame(minHeight: 80)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
        } header: {
            Text(L("高级选项"))
        } footer: {
            Text(L("一行一项 docker flag，可写 --flag=value 形式。空行与 # 开头行忽略。"))
        }
        .listRowBackground(Color.connSurface)
    }

    private var previewSection: some View {
        Section {
            Text(previewCommand)
                .font(.connData(.footnote))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let onSaveAsCommand {
                Button {
                    saveAsCommand(via: onSaveAsCommand)
                } label: {
                    Label(L("保存到本地命令"), systemImage: "square.and.arrow.down")
                }
                .disabled(!state.isValid || isCommandSaved)
            }
            if let savedTitle {
                Label(String(format: L("已保存：%@"), savedTitle), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.connGood)
                    .font(.connFootnote)
            }
        } header: {
            Text(L("预览命令"))
        }
        .listRowBackground(Color.connSurface)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage {
            Section {
                ConnBanner(errorMessage, systemImage: "exclamationmark.triangle")
            }
            .listRowBackground(Color.connSurface)
        }
    }

    private var previewCommand: String {
        DockerCommand.createVolume(state.draft, sudo: false)
    }

    private func submit() {
        guard state.isValid else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            let outcome = await operations.createVolume(state.draft)
            isSubmitting = false
            if outcome.isSuccess {
                dismiss()
            } else {
                errorMessage = DockerOperationFeedback.message(for: outcome, label: L("创建卷"))
            }
        }
    }

    private func saveAsCommand(via onSave: @escaping DockerCommandSaveHandler) {
        guard !isCommandSaved else { return }
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? L("创建卷") : "\(L("创建卷")) \(name)"
        do {
            try onSave(title, previewCommand)
            savedTitle = title
            isCommandSaved = true
        } catch {
            errorMessage = String(
                format: L("保存失败：%@"),
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }
}

/// 网络创建表单：保留常用的 internal / attachable 开关，其余 Docker flag 使用文本输入。
struct DockerNetworkFormView: View {
    let operations: DockerOperationsModel
    let onSaveAsCommand: DockerCommandSaveHandler?
    @Environment(\.dismiss) private var dismiss
    @State private var state = DockerNetworkFormState()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var savedTitle: String?
    @State private var isCommandSaved = false

    init(
        operations: DockerOperationsModel,
        onSaveAsCommand: DockerCommandSaveHandler? = nil
    ) {
        self.operations = operations
        self.onSaveAsCommand = onSaveAsCommand
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("基本")) {
                    TextField(L("名称"), text: $state.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("驱动"), text: $state.driver)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle(L("内部网络"), isOn: $state.isInternal)
                    Toggle(L("可附加"), isOn: $state.isAttachable)
                }
                .listRowBackground(Color.connSurface)
                advancedSection
                previewSection
                errorSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("创建网络"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L("创建"))
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!state.isValid || !operations.isWriteAvailable || isSubmitting)
                }
            }
        }
    }

    private var advancedSection: some View {
        Section {
            TextEditor(text: $state.otherOptionsText)
                .font(.connData(.footnote))
                .frame(minHeight: 80)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
        } header: {
            Text(L("高级选项"))
        } footer: {
            Text(L("一行一项 docker flag，可写 --flag=value 形式。空行与 # 开头行忽略。"))
        }
        .listRowBackground(Color.connSurface)
    }

    private var previewSection: some View {
        Section {
            Text(previewCommand)
                .font(.connData(.footnote))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let onSaveAsCommand {
                Button {
                    saveAsCommand(via: onSaveAsCommand)
                } label: {
                    Label(L("保存到本地命令"), systemImage: "square.and.arrow.down")
                }
                .disabled(!state.isValid || isCommandSaved)
            }
            if let savedTitle {
                Label(String(format: L("已保存：%@"), savedTitle), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.connGood)
                    .font(.connFootnote)
            }
        } header: {
            Text(L("预览命令"))
        }
        .listRowBackground(Color.connSurface)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage {
            Section {
                ConnBanner(errorMessage, systemImage: "exclamationmark.triangle")
            }
            .listRowBackground(Color.connSurface)
        }
    }

    private var previewCommand: String {
        DockerCommand.createNetwork(state.draft, sudo: false)
    }

    private func submit() {
        guard state.isValid else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            let outcome = await operations.createNetwork(state.draft)
            isSubmitting = false
            if outcome.isSuccess {
                dismiss()
            } else {
                errorMessage = DockerOperationFeedback.message(for: outcome, label: L("创建网络"))
            }
        }
    }

    private func saveAsCommand(via onSave: @escaping DockerCommandSaveHandler) {
        guard !isCommandSaved else { return }
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? L("创建网络") : "\(L("创建网络")) \(name)"
        do {
            try onSave(title, previewCommand)
            savedTitle = title
            isCommandSaved = true
        } catch {
            errorMessage = String(
                format: L("保存失败：%@"),
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }
}
