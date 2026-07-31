import ConnOps
import ConnUI
import SwiftUI

/// 强类型 destructive sheet：它只认识 `DockerPendingAction`，绝不会把用户输入拼成命令。
/// 远端执行唯一经过 `confirmPendingAction(confirmation:)`，由 Operations 复用同一 gate、
/// 审计和刷新策略。
struct DockerDestructiveConfirmationView: View {
    let operations: DockerOperationsModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                if let action = operations.pendingDestructiveAction {
                    Section(L("确认 Docker 操作")) {
                        if let impactMessage = action.impactMessage {
                            ConnBanner(
                                impactMessage,
                                systemImage: "exclamationmark.triangle",
                                kind: .warn
                            )
                        }
                        Text(action.confirmationMessage).foregroundStyle(.connMuted)
                        TextField(L("确认词"), text: $confirmation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .listRowBackground(Color.connSurface)
                    pruneOptions(action)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("确认 Docker 操作"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: operations.pendingDestructiveAction) { _, _ in confirmation = "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) {
                        operations.cancelPendingAction()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, role: .destructive) {
                        let input = confirmation
                        Task {
                            if await operations.confirmPendingAction(confirmation: input) {
                                dismiss()
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!operations.canConfirmPendingAction(input: confirmation) || !operations.isWriteAvailable)
                }
            }
        }
    }

    @ViewBuilder
    private func pruneOptions(_ action: DockerPendingAction) -> some View {
        if case let .systemPrune(options) = action {
            Section(L("清理范围")) {
                Text(L("默认将移除已停止容器、未使用网络、悬空镜像和构建缓存。"))
                    .foregroundStyle(.connMuted)
                Toggle(L("移除所有未使用镜像"), isOn: pruneBinding(\.allUnusedImages, options: options))
                Toggle(L("包含未使用卷"), isOn: pruneBinding(\.includeVolumes, options: options))
            }
            .listRowBackground(Color.connSurface)
        }
    }

    private var actionTitle: String {
        operations.pendingDestructiveAction?.confirmationButtonTitle ?? L("删除")
    }

    private func pruneBinding(
        _ keyPath: KeyPath<DockerSystemPruneOptions, Bool>, options: DockerSystemPruneOptions
    ) -> Binding<Bool> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { newValue in
                let updated = DockerSystemPruneOptions(
                    allUnusedImages: keyPath == \.allUnusedImages ? newValue : options.allUnusedImages,
                    includeVolumes: keyPath == \.includeVolumes ? newValue : options.includeVolumes
                )
                operations.requestDestructiveAction(.systemPrune(updated))
                confirmation = ""
            }
        )
    }
}
