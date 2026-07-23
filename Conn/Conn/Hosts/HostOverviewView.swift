import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI

/// 单机概览（原型 S3 概览段）：实时指标环 + 系统信息 + Top 进程（可 kill）。
///
/// 监控生命周期由父级 `HostDetailView` 统一起停（切段时监控不断），本视图只消费
/// 共享的 `HostOverviewViewModel`。
struct HostOverviewView: View {
    let viewModel: HostOverviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.md) {
            gauges
            if let error = viewModel.errorText, viewModel.latest == nil {
                ConnBanner(error, systemImage: "wifi.slash")
            }
            systemInfo
            processes
        }
        .padding(.bottom, ConnSpacing.lg)
        .confirmationDialog(
            killPrompt,
            isPresented: killDialogBinding,
            titleVisibility: .visible
        ) {
            Button(L("结束进程"), role: .destructive) {
                Task { await viewModel.confirmKill() }
            }
            Button(L("取消"), role: .cancel) { viewModel.killTarget = nil }
        }
        .alert(L("进程操作"), isPresented: actionMessageBinding) {
            Button(L("好"), role: .cancel) { viewModel.actionMessage = nil }
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
    }

    // MARK: - 指标环

    private var gauges: some View {
        HStack(spacing: ConnSpacing.xs) {
            MetricGauge(label: "CPU", value: viewModel.latest?.cpu, tint: .connAccent)
            MetricGauge(label: L("内存"), value: viewModel.latest?.mem, tint: .connInfo)
            MetricGauge(label: L("磁盘"), value: viewModel.latest?.disk, tint: .connDisk)
        }
    }

    // MARK: - 系统信息

    private var systemInfo: some View {
        VStack(spacing: 0) {
            infoRow(L("负载（1 分钟）"), value: viewModel.latest?.load1.map { String(format: "%.2f", $0) } ?? "—")
            hairline
            infoRow(L("磁盘"), value: diskText)
            hairline
            infoRow(L("运行时长"), value: uptimeText)
        }
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.connSubheadline).foregroundStyle(.connMuted)
            Spacer()
            Text(value).font(.connData()).connTabularNumbers().foregroundStyle(.connInk)
        }
        .padding(.horizontal, ConnSpacing.cardPadding)
        .padding(.vertical, ConnSpacing.sm)
    }

    private var hairline: some View {
        Rectangle().fill(Color.connLine).frame(height: 0.5).padding(.leading, ConnSpacing.cardPadding)
    }

    // MARK: - 进程

    private var processes: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("进程 · CPU 占用前列"))
                .font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            if viewModel.topProcesses.isEmpty {
                Text(viewModel.latest == nil ? L("采集中…") : L("暂无进程数据"))
                    .font(.connFootnote).foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.sm)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.topProcesses.enumerated()), id: \.element.id) { index, process in
                        if index > 0 { hairline }
                        processRow(process)
                    }
                }
                .connSurface(cornerRadius: ConnRadius.card)
            }
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

    // MARK: - 派生文本 / 绑定

    private var diskText: String {
        guard let sample = viewModel.latest?.sample, sample.diskTotal > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        let used = formatter.string(fromByteCount: Int64(sample.diskUsed))
        let total = formatter.string(fromByteCount: Int64(sample.diskTotal))
        return "\(used) / \(total)"
    }

    private var uptimeText: String {
        guard let seconds = viewModel.latest?.uptimeSeconds else { return "—" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        return days > 0 ? String(format: L("%d 天 %d 小时"), days, hours) : String(format: L("%d 小时"), hours)
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
