import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI

/// 进程段：CPU 占用前列进程 + 结束（二次确认）。从概览拆出为独立段。
struct ProcessListView: View {
    let viewModel: HostOverviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("进程 · CPU 占用前列"))
                .font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            if viewModel.topProcesses.isEmpty {
                Text(viewModel.latest == nil ? L("采集中…") : L("暂无进程数据"))
                    .font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.topProcesses.enumerated()), id: \.element.id) { index, process in
                        if index > 0 {
                            Rectangle().fill(Color.connLine).frame(height: 0.5)
                                .padding(.leading, ConnSpacing.cardPadding)
                        }
                        processRow(process)
                    }
                }
                .connSurface(cornerRadius: ConnRadius.card)
            }
        }
        .padding(.bottom, ConnSpacing.lg)
        .confirmationDialog(killPrompt, isPresented: killDialogBinding, titleVisibility: .visible) {
            Button(L("结束进程"), role: .destructive) { Task { await viewModel.confirmKill() } }
            Button(L("取消"), role: .cancel) { viewModel.killTarget = nil }
        }
        .alert(L("进程操作"), isPresented: actionMessageBinding) {
            Button(L("好"), role: .cancel) { viewModel.actionMessage = nil }
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
    }

    private func processRow(_ process: RemoteProcess) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.command).font(.connBody).foregroundStyle(.connInk).lineLimit(1)
                Text("PID \(String(process.pid))").font(.connData(.caption2)).foregroundStyle(.connMuted)
            }
            Spacer(minLength: ConnSpacing.xs)
            usageColumn("CPU", value: process.cpu)
            usageColumn(L("内存"), value: process.mem)
            Button {
                viewModel.requestKill(process)
            } label: {
                Image(systemName: "xmark.circle").font(.system(size: 18)).foregroundStyle(.connCrit)
            }
            .buttonStyle(.plain)
            .connHitTarget()
            .accessibilityLabel("结束 \(process.command)")
        }
        .padding(.horizontal, ConnSpacing.cardPadding)
        .padding(.vertical, ConnSpacing.sm)
    }

    private func usageColumn(_ label: String, value: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(String(format: "%.0f%%", value)).font(.connData(.footnote)).connTabularNumbers()
                .foregroundStyle(value > ConnThreshold.warn ? .connWarn : .connInk)
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
        }
        .frame(width: 44)
    }

    private var killPrompt: String {
        guard let target = viewModel.killTarget else { return "" }
        return String(format: L("结束 %@（PID %d）？将发送 SIGTERM。"), target.command, target.pid)
    }

    private var killDialogBinding: Binding<Bool> {
        Binding(get: { viewModel.killTarget != nil }, set: { if !$0 { viewModel.killTarget = nil } })
    }

    private var actionMessageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }
}
