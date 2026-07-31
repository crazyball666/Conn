import ConnOps
import ConnUI
import SwiftUI

struct DockerRunReviewView: View {
    let draft: DockerRunDraft
    let operations: DockerOperationsModel
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !risks.isEmpty {
                Section(L("高风险配置")) {
                    ForEach(risks, id: \.self) { risk in
                        Label(risk.title, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.connWarn)
                    }
                }
            }
            Section(L("有效配置")) {
                Text(command)
                    .font(.connData(.footnote))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Section {
                    ConnBanner(errorMessage, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("复核配置"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSubmitting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("返回")) { dismiss() }
                    .disabled(isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(L("创建容器"))
                    }
                }
                .fontWeight(.semibold)
                .disabled(!operations.isWriteAvailable || isSubmitting)
            }
        }
    }

    private var risks: [DockerRunRisk] { DockerRunRiskDetector.detect(draft) }

    /// 复核的是即将交给 SSH 的 docker argv（不含是否走 sudo 的环境差异），
    /// 因此必须复用真正的命令构造器，不能单独拼一个只用于显示的近似版本。
    private var command: String { DockerCommand.run(draft, sudo: false) }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            let outcome = await operations.runContainer(draft)
            isSubmitting = false
            if outcome.isSuccess {
                completed()
            } else {
                errorMessage = DockerOperationFeedback.message(
                    for: outcome,
                    label: L("创建容器")
                )
            }
        }
    }
}
