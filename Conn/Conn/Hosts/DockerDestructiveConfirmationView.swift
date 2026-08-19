import ConnOps
import ConnUI
import SwiftUI

/// 把统一的删除 / 清理 Alert 安装在当前可见的导航层级上。SwiftUI 不会可靠地从
/// 已被 `navigationDestination` 覆盖的父页面呈现 Alert，因此根列表与各详情页共用
/// 这个 modifier，但同一时刻只允许当前可见层响应 pending action。
private struct DockerDestructiveConfirmationAlertModifier: ViewModifier {
    let operations: DockerOperationsModel
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.alert(
            operations.pendingDestructiveAction?.alertTitle ?? L("确认 Docker 操作"),
            isPresented: Binding(
                get: {
                    isEnabled
                        && operations.pendingDestructiveAction?.confirmationStyle == .alert
                },
                // Alert 只能由按钮关闭；确认按钮会异步读取 pending action，不能让
                // SwiftUI 的写回先清掉它。取消按钮会显式调用 cancel。
                set: { _ in }
            ),
            presenting: operations.pendingDestructiveAction
        ) { action in
            Button(L("取消"), role: .cancel) {
                operations.cancelPendingAction()
            }
            Button(action.confirmationButtonTitle, role: .destructive) {
                Task { await operations.confirmPendingAlertAction() }
            }
            .disabled(!operations.isWriteAvailable)
        } message: { action in
            Text(action.alertMessage)
        }
    }
}

extension View {
    func dockerDestructiveConfirmationAlert(
        operations: DockerOperationsModel,
        isEnabled: Bool = true
    ) -> some View {
        modifier(DockerDestructiveConfirmationAlertModifier(
            operations: operations,
            isEnabled: isEnabled
        ))
    }
}

/// 仅用于生产环境非删除操作的输入式强确认。删除与清理操作统一由系统 Alert 呈现，
/// 不会再进入这个 sheet。
struct DockerTypedConfirmationView: View {
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
                        Text(action.typedConfirmationMessage).foregroundStyle(.connMuted)
                        TextField(L("确认词"), text: $confirmation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .listRowBackground(Color.connSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("确认 Docker 操作"))
            .navigationBarTitleDisplayMode(.inline)
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

    private var actionTitle: String {
        operations.pendingDestructiveAction?.confirmationButtonTitle ?? L("删除")
    }

}

/// `docker system prune` 的范围选择仍是表单；“继续”只暂存选项，表单完全关闭后
/// 再由父视图弹出统一的系统 Alert，避免两个 presentation 同时竞争。
struct DockerSystemPruneOptionsView: View {
    let onContinue: (DockerSystemPruneOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var allUnusedImages = false
    @State private var includeVolumes = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L("清理范围")) {
                    Text(L("默认将移除已停止容器、未使用网络、悬空镜像和构建缓存。"))
                        .foregroundStyle(.connMuted)
                    Toggle(L("移除所有未使用镜像"), isOn: $allUnusedImages)
                    Toggle(L("包含未使用卷"), isOn: $includeVolumes)
                }
                .listRowBackground(Color.connSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("清理 Docker 资源"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("继续")) {
                        onContinue(DockerSystemPruneOptions(
                            allUnusedImages: allUnusedImages,
                            includeVolumes: includeVolumes
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
