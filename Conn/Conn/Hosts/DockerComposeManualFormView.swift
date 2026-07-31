import ConnOps
import ConnUI
import SwiftUI

struct DockerComposeManualFormView: View {
    let model: DockerComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var configFile = ""
    @State private var projectDirectory = ""
    @State private var projectName = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("配置文件绝对路径"), text: $configFile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("项目目录（可选）"), text: $projectDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("项目名称（可选）"), text: $projectName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L("项目配置"))
                } footer: {
                    if let project = draft.project {
                        Text(String(format: L("将使用项目名称：%@"), project.name))
                    } else {
                        Text(L("配置文件必须使用服务器上的绝对路径。"))
                    }
                }
                .listRowBackground(Color.connSurface)
                if let error = model.errorMessage {
                    Section {
                        ConnBanner(error, systemImage: "exclamationmark.triangle")
                    }
                    .listRowBackground(Color.connSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("手动添加 Compose 项目"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("添加")) {
                        isSubmitting = true
                        Task {
                            if await model.addManualProject(draft) {
                                dismiss()
                            } else {
                                isSubmitting = false
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!draft.validate().isEmpty || isSubmitting)
                }
            }
        }
    }

    private var draft: DockerComposeManualDraft {
        DockerComposeManualDraft(
            configFile: configFile,
            projectDirectory: projectDirectory,
            projectName: projectName
        )
    }
}
