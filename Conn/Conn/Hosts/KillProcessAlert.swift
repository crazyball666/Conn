import ConnMonitor
import ConnUI
import SwiftUI

/// 结束进程的二次确认 + 结果提示。进程列表与进程详情共用。
///
/// 各视图自持有本地 `target` / `result` 状态并挂载本修饰符——详情页是列表推入的
/// 子层，把对话框集中到祖先视图时，祖先被覆盖会导致对话框不呈现；故每个触发点
/// 就地呈现最稳。确认后调用 `viewModel.performKill` 并把结果落到 `result` 弹提示。
struct KillProcessAlert: ViewModifier {
    let viewModel: HostOverviewViewModel
    @Binding var target: RemoteProcess?
    @Binding var result: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(prompt, isPresented: confirmBinding, titleVisibility: .visible) {
                Button(L("结束进程"), role: .destructive) {
                    guard let process = target else { return }
                    target = nil
                    Task { result = await viewModel.performKill(process) }
                }
                Button(L("取消"), role: .cancel) { target = nil }
            }
            .alert(L("进程操作"), isPresented: resultBinding) {
                Button(L("好"), role: .cancel) { result = nil }
            } message: {
                Text(result ?? "")
            }
    }

    private var prompt: String {
        guard let process = target else { return "" }
        return String(format: L("结束 %@（PID %d）？将发送 SIGTERM。"), process.command, process.pid)
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }

    private var resultBinding: Binding<Bool> {
        Binding(get: { result != nil }, set: { if !$0 { result = nil } })
    }
}
