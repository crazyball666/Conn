import ConnUI
import SwiftUI

/// 镜像拉取的唯一进度呈现。它不拥有 task、返回栈或取消入口；`DockerView` 的顶层
/// `fullScreenCover(item:)` 负责生命周期，Operations 的终态是可关闭与否的唯一依据。
struct DockerPullProgressView: View {
    let operations: DockerOperationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.md) {
            HStack(spacing: ConnSpacing.sm) {
                if operations.isPullActive {
                    ProgressView().controlSize(.small)
                    Text(L("正在拉取镜像")).font(.connHeadline)
                } else {
                    Image(systemName: resultIcon).foregroundStyle(resultColor)
                    Text(resultTitle).font(.connHeadline)
                }
                Spacer()
            }
            ScrollView {
                Text(operations.pullPresentation?.logs.isEmpty == false
                    ? operations.pullPresentation?.logs ?? ""
                    : L("等待远端输出…"))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.connInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .padding(ConnSpacing.sm)
            .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.card))
            if operations.canDismissPull {
                Button(L("完成")) { operations.dismissPullProgress() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(ConnSpacing.page)
        .background(Color.connBg.ignoresSafeArea())
        .interactiveDismissDisabled(true)
        .accessibilityIdentifier("docker-pull-progress")
    }

    private var resultIcon: String {
        guard let result = operations.pullPresentation?.result else { return "arrow.down.circle" }
        return result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var resultColor: Color {
        operations.pullPresentation?.result?.isSuccess == true ? .connGood : .connWarn
    }

    private var resultTitle: String {
        Self.resultTitle(for: operations.pullPresentation?.result)
    }

    static func resultTitle(for result: DockerOperationResultState?) -> String {
        guard let result else { return L("拉取镜像") }
        if result.isSuccess { return L("拉取完成") }
        if let exitCode = result.exitCode {
            return String(format: L("%@ 失败（退出码 %d）"), L("拉取镜像"), exitCode)
        }
        return L("拉取结果未知")
    }
}

/// pull 的引用输入属于普通 OperationSheet；真正的流式展示只会在提交后由顶层 cover 接管。
struct DockerPullFormView: View {
    let operations: DockerOperationsModel
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(L("镜像")) {
                    TextField(L("镜像引用"), text: $reference)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .listRowBackground(Color.connSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("拉取镜像"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("拉取")) {
                        operations.startPull(reference: reference)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !operations.isWriteAvailable)
                }
            }
        }
    }
}
