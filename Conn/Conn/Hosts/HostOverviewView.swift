import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI

/// 单机概览：分块（系统 / CPU / 内存 / 网络 / 磁盘 IO / 进程），
/// 变化型指标用折线图展示趋势（实时累积最近 40 个采样点）。
struct HostOverviewView: View {
    let viewModel: HostOverviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.md) {
            if let error = viewModel.errorText, viewModel.latest == nil {
                ConnBanner(error, systemImage: "wifi.slash")
            }
            systemCard
            cpuSection
            memorySection
            networkSection
            ioSection
            processes
        }
        .padding(.bottom, ConnSpacing.lg)
        .onChange(of: viewModel.latest) { _, _ in viewModel.record() }
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

    // MARK: - 系统

    private var systemCard: some View {
        section(L("系统")) {
            infoRows([
                (L("核心数"), MetricFormat.cores(latest?.cpuCores)),
                (L("内存"), MetricFormat.pair(used: latest?.memUsedBytes, total: latest?.memTotalBytes)),
                (L("磁盘"), MetricFormat.pair(used: latest?.diskUsedBytes, total: latest?.diskTotalBytes)),
                (L("负载（1 分钟）"), MetricFormat.load(latest?.load1)),
                (L("运行时长"), MetricFormat.uptime(latest?.uptimeSeconds))
            ])
        }
    }

    // MARK: - CPU / 内存（百分比 + 面积图）

    private var cpuSection: some View {
        section("CPU") {
            percentHeader(latest?.cpu, detail: MetricFormat.cores(latest?.cpuCores))
            chartOrPlaceholder(
                [TrendSeries(id: "cpu", color: .connAccent, values: viewModel.cpuHistory)],
                domain: 0 ... 100, yFormat: { "\(Int($0))" }
            )
        }
    }

    private var memorySection: some View {
        section(L("内存")) {
            percentHeader(
                latest?.mem,
                detail: MetricFormat.pair(used: latest?.memUsedBytes, total: latest?.memTotalBytes)
            )
            chartOrPlaceholder(
                [TrendSeries(id: "mem", color: .connInfo, values: viewModel.memHistory)],
                domain: 0 ... 100, yFormat: { "\(Int($0))" }
            )
        }
    }

    private func percentHeader(_ value: Double?, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { "\(Int($0))" } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .connTabularNumbers()
                    .foregroundStyle(.connInk)
                Text("%").font(.connSubheadline).foregroundStyle(.connMuted)
            }
            Spacer()
            Text(detail).font(.connData(.footnote)).foregroundStyle(.connMuted)
        }
    }

    // MARK: - 网络 / 磁盘 IO（双向速率折线 + 明细行）

    private var networkSection: some View {
        section(L("网络")) {
            legend([(L("下行"), .connInfo), (L("上行"), .connGood)])
            chartOrPlaceholder(rateSeries(
                down: viewModel.netRxHistory, downColor: .connInfo,
                up: viewModel.netTxHistory, upColor: .connGood
            ))
            infoRows([
                (L("下行速率"), MetricFormat.rate(latest?.netRxRate)),
                (L("上行速率"), MetricFormat.rate(latest?.netTxRate)),
                (L("下行总量"), MetricFormat.bytes(latest?.netRx)),
                (L("上行总量"), MetricFormat.bytes(latest?.netTx))
            ])
        }
    }

    private var ioSection: some View {
        section(L("磁盘 IO")) {
            legend([(L("读"), .connDisk), (L("写"), .connWarn)])
            chartOrPlaceholder(rateSeries(
                down: viewModel.ioReadHistory, downColor: .connDisk,
                up: viewModel.ioWriteHistory, upColor: .connWarn
            ))
            infoRows([
                (L("读速率"), MetricFormat.rate(latest?.ioReadRate)),
                (L("写速率"), MetricFormat.rate(latest?.ioWriteRate)),
                (L("读总量"), MetricFormat.bytes(latest?.ioReadBytes)),
                (L("写总量"), MetricFormat.bytes(latest?.ioWriteBytes))
            ])
        }
    }

    private func rateSeries(down: [Double], downColor: Color, up: [Double], upColor: Color) -> [TrendSeries] {
        [
            TrendSeries(id: "down", color: downColor, values: down),
            TrendSeries(id: "up", color: upColor, values: up)
        ]
    }

    // MARK: - 通用块

    /// 眉标 + Surface 卡片。
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(title).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                content()
            }
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .connSurface(cornerRadius: ConnRadius.card)
        }
    }

    /// 折线图；历史不足 2 点时显示等高占位（避免布局跳动）。
    private func chartOrPlaceholder(
        _ series: [TrendSeries],
        domain: ClosedRange<Double>? = nil,
        yFormat: @escaping (Double) -> String = { MetricFormat.compactBytes($0) + "/s" }
    ) -> some View {
        let hasData = series.contains { $0.values.count >= 2 }
        let resolved = domain ?? autoDomain(series)
        return Group {
            if hasData {
                MetricTrendChart(series: series, yDomain: resolved, yFormat: yFormat)
            } else {
                Text(L("采集中…"))
                    .font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
            }
        }
    }

    /// 速率图自动 Y 域：峰值上浮 25%，下限 1 KB 防止空图压扁。
    private func autoDomain(_ series: [TrendSeries]) -> ClosedRange<Double> {
        let peak = series.flatMap { $0.values }.max() ?? 0
        return 0 ... max(peak * 1.25, 1024)
    }

    private func legend(_ items: [(String, Color)]) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Circle().fill(item.1).frame(width: 7, height: 7)
                    Text(item.0).font(.connData(.caption2)).foregroundStyle(.connMuted)
                }
            }
            Spacer()
        }
    }

    private func infoRows(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(Color.connLine).frame(height: 0.5)
                }
                HStack {
                    Text(row.0).font(.connSubheadline).foregroundStyle(.connMuted)
                    Spacer()
                    Text(row.1).font(.connData()).connTabularNumbers().foregroundStyle(.connInk)
                }
                .padding(.vertical, ConnSpacing.sm)
            }
        }
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

    // MARK: - 派生 / 绑定

    private var latest: HostMetrics? { viewModel.latest }

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
