import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI

/// 单机概览：分块（系统 / 负载 / CPU / 内存 / 磁盘 / 网络 / 进程）。
/// CPU 显示各核折线、内存显示三段堆叠占比、磁盘与磁盘 IO 合并一块。
struct HostOverviewView: View {
    let viewModel: HostOverviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.md) {
            if let error = viewModel.errorText, viewModel.latest == nil {
                ConnBanner(error, systemImage: "wifi.slash")
            }
            systemCard
            loadCard
            cpuSection
            memorySection
            diskSection
            networkSection
            processes
        }
        .padding(.bottom, ConnSpacing.lg)
        .onChange(of: viewModel.latest) { _, _ in viewModel.record() }
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

    // MARK: - 系统 / 负载

    private var systemCard: some View {
        section(L("系统")) {
            infoRows([
                (L("操作系统"), latest?.osName ?? "—"),
                (L("运行时长"), MetricFormat.uptime(latest?.uptimeSeconds))
            ])
        }
    }

    private var loadCard: some View {
        section(L("负载")) {
            HStack(spacing: 0) {
                loadColumn(L("1 分钟"), latest?.load1)
                loadDivider
                loadColumn(L("5 分钟"), latest?.load5)
                loadDivider
                loadColumn(L("15 分钟"), latest?.load15)
            }
        }
    }

    private func loadColumn(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 3) {
            Text(MetricFormat.load(value))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .connTabularNumbers().foregroundStyle(.connInk)
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var loadDivider: some View {
        Rectangle().fill(Color.connLine).frame(width: 0.5, height: 28)
    }

    // MARK: - CPU（型号 + 各核折线）

    private var cpuSection: some View {
        section("CPU") {
            if let model = latest?.cpuModel, !model.isEmpty {
                Text(model)
                    .font(.connData(.caption2)).foregroundStyle(.connMuted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            percentHeader(latest?.cpu, detail: MetricFormat.cores(latest?.cpuCores))
            cpuBreakdownGrid
            cpuCompositionChart
            cpuPerCoreBars
        }
    }

    // MARK: - 内存（三段堆叠占比 + 明细）

    private var memorySection: some View {
        section(L("内存")) {
            percentHeader(
                latest?.mem,
                detail: MetricFormat.pair(used: latest?.memUsedBytes, total: latest?.memTotalBytes)
            )
            chartOrPlaceholder(memSeries, domain: 0 ... 100, yFormat: { "\(Int($0))" }, stacked: true)
            HStack(spacing: 0) {
                breakdownColumn(L("已用"), MetricFormat.bytes(latest?.memUsedBytes), .connCrit)
                breakdownColumn(L("缓存"), MetricFormat.bytes(latest?.memBuffersCache), .connWarn)
                breakdownColumn(L("空闲"), MetricFormat.bytes(latest?.memFree), .connGood)
            }
        }
    }

    private var memSeries: [TrendSeries] {
        [
            TrendSeries(id: L("已用"), color: .connCrit, values: viewModel.memUsedHistory),
            TrendSeries(id: L("缓存"), color: .connWarn, values: viewModel.memCacheHistory),
            TrendSeries(id: L("空闲"), color: .connGood, values: viewModel.memFreeHistory)
        ]
    }

    private func breakdownColumn(_ label: String, _ value: String, _ dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            }
            Text(value).font(.connData(.footnote)).connTabularNumbers().foregroundStyle(.connInk)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 磁盘（占用条 + 磁盘 IO 折线，合并一块）

    private var diskSection: some View {
        section(L("磁盘")) {
            percentHeader(
                latest?.disk,
                detail: MetricFormat.pair(used: latest?.diskUsedBytes, total: latest?.diskTotalBytes)
            )
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.connTrack)
                    Capsule().fill(diskColor)
                        .frame(width: max(6, geometry.size.width * fraction(latest?.disk)))
                }
            }
            .frame(height: 8)
            Rectangle().fill(Color.connLine).frame(height: 0.5).padding(.vertical, 2)
            chartHeader(
                legend: [(L("读"), .connDisk), (L("写"), .connWarn)],
                totals: "\(L("读")) \(MetricFormat.bytes(latest?.ioReadBytes))  \(L("写")) \(MetricFormat.bytes(latest?.ioWriteBytes))"
            )
            chartOrPlaceholder(rateSeries(
                down: viewModel.ioReadHistory, downColor: .connDisk,
                up: viewModel.ioWriteHistory, upColor: .connWarn
            ))
        }
    }

    private var diskColor: Color {
        guard let value = latest?.disk else { return .connTrack }
        if value > ConnThreshold.crit { return .connCrit }
        if value > ConnThreshold.warn { return .connWarn }
        return .connDisk
    }

    // MARK: - 网络（双向折线 + 右上角累计量）

    private var networkSection: some View {
        section(L("网络")) {
            chartHeader(
                legend: [(L("下行"), .connInfo), (L("上行"), .connGood)],
                totals: "↓ \(MetricFormat.bytes(latest?.netRx))  ↑ \(MetricFormat.bytes(latest?.netTx))"
            )
            chartOrPlaceholder(rateSeries(
                down: viewModel.netRxHistory, downColor: .connInfo,
                up: viewModel.netTxHistory, upColor: .connGood
            ))
        }
    }

    private func rateSeries(down: [Double], downColor: Color, up: [Double], upColor: Color) -> [TrendSeries] {
        [
            TrendSeries(id: "down", color: downColor, values: down),
            TrendSeries(id: "up", color: upColor, values: up)
        ]
    }

    // MARK: - 通用块

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

    private func percentHeader(_ value: Double?, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { "\(Int($0))" } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .connTabularNumbers().foregroundStyle(.connInk)
                Text("%").font(.connSubheadline).foregroundStyle(.connMuted)
            }
            Spacer()
            Text(detail).font(.connData(.footnote)).foregroundStyle(.connMuted)
        }
    }

    /// 图表上方：图例（左）+ 累计量（右上角小字）。
    private func chartHeader(legend: [(String, Color)], totals: String) -> some View {
        HStack {
            HStack(spacing: ConnSpacing.sm) {
                ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Circle().fill(item.1).frame(width: 7, height: 7)
                        Text(item.0).font(.connData(.caption2)).foregroundStyle(.connMuted)
                    }
                }
            }
            Spacer()
            Text(totals).font(.connData(.caption2)).foregroundStyle(.connDim)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func chartOrPlaceholder(
        _ series: [TrendSeries],
        domain: ClosedRange<Double>? = nil,
        yFormat: @escaping (Double) -> String = { MetricFormat.compactBytes($0) + "/s" },
        stacked: Bool = false
    ) -> some View {
        let hasData = series.contains { $0.values.count >= 2 }
        let resolved = domain ?? autoDomain(series)
        return Group {
            if hasData {
                MetricTrendChart(series: series, yDomain: resolved, yFormat: yFormat, stacked: stacked)
            } else {
                Text(L("采集中…"))
                    .font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity).frame(height: 58)
            }
        }
    }

    private func autoDomain(_ series: [TrendSeries]) -> ClosedRange<Double> {
        let peak = series.flatMap { $0.values }.max() ?? 0
        return 0 ... max(peak * 1.25, 1024)
    }

    private func fraction(_ value: Double?) -> CGFloat {
        guard let value else { return 0 }
        return min(max(value / 100, 0), 1)
    }

    private func infoRows(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(Color.connLine).frame(height: 0.5)
                }
                HStack(spacing: ConnSpacing.sm) {
                    Text(row.0).font(.connSubheadline).foregroundStyle(.connMuted)
                    Spacer()
                    Text(row.1).font(.connData()).connTabularNumbers().foregroundStyle(.connInk)
                        .lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing)
                }
                .padding(.vertical, ConnSpacing.sm)
            }
        }
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

// MARK: - CPU 明细（各类占比网格 + 构成堆叠图 + 各核占用条）

/// CPU 各类时间占比的一格（标签 + 值 + 颜色）。
private struct CPUStatItem: Identifiable {
    let label: String
    let value: Double?
    let color: Color
    var id: String { label }
}

private extension HostOverviewView {
    var cpuBreakdownGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
            spacing: ConnSpacing.sm
        ) {
            ForEach(cpuBreakdownItems) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).font(.connData(.caption2)).foregroundStyle(.connMuted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Text(item.value.map { String(format: "%.1f%%", $0) } ?? "—")
                        .font(.connData(.footnote)).connTabularNumbers().foregroundStyle(.connInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var cpuBreakdownItems: [CPUStatItem] {
        let breakdown = viewModel.latest?.cpuBreakdown
        return [
            CPUStatItem(label: L("用户"), value: breakdown?.user, color: .connAccent),
            CPUStatItem(label: L("系统"), value: breakdown?.system, color: .connInfo),
            CPUStatItem(label: L("IO 等待"), value: breakdown?.iowait, color: .connWarn),
            CPUStatItem(label: L("空闲"), value: breakdown?.idle, color: .connDim),
            CPUStatItem(label: L("nice"), value: breakdown?.nice, color: .connGood),
            CPUStatItem(label: L("硬中断"), value: breakdown?.irq, color: .connDisk),
            CPUStatItem(label: L("软中断"), value: breakdown?.softirq, color: .connCrit),
            CPUStatItem(label: L("抢占"), value: breakdown?.steal, color: .connMuted)
        ]
    }

    /// CPU 构成堆叠面积图（用户/系统/iowait/其他/空闲，堆到 100%）。空闲呈主导灰。
    var cpuCompositionChart: some View {
        chartOrPlaceholder([
            TrendSeries(id: L("用户"), color: .connAccent, values: viewModel.cpuUserHistory),
            TrendSeries(id: L("系统"), color: .connInfo, values: viewModel.cpuSystemHistory),
            TrendSeries(id: L("IO 等待"), color: .connWarn, values: viewModel.cpuIowaitHistory),
            TrendSeries(id: L("其他"), color: .connGood, values: viewModel.cpuOtherHistory),
            TrendSeries(id: L("空闲"), color: .connTrack, values: viewModel.cpuIdleHistory)
        ], domain: 0 ... 100, yFormat: { "\(Int($0))" }, stacked: true)
    }

    var cpuPerCoreBars: some View {
        let cores = viewModel.latest?.cpuPerCore ?? []
        return VStack(spacing: 6) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, usage in
                HStack(spacing: ConnSpacing.sm) {
                    Text("CPU\(index)")
                        .font(.connData(.caption2)).foregroundStyle(.connMuted)
                        .frame(width: 42, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.connTrack)
                            Capsule().fill(coreBarColor(usage))
                                .frame(width: max(4, geometry.size.width * fraction(usage)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int(usage))%")
                        .font(.connData(.caption2)).connTabularNumbers().foregroundStyle(.connInk)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    func coreBarColor(_ usage: Double) -> Color {
        if usage > ConnThreshold.crit { return .connCrit }
        if usage > ConnThreshold.warn { return .connWarn }
        return .connAccent
    }
}

// MARK: - 进程

private extension HostOverviewView {
    var processes: some View {
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

    func processRow(_ process: RemoteProcess) -> some View {
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

    func usageColumn(_ label: String, value: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(String(format: "%.0f%%", value)).font(.connData(.footnote)).connTabularNumbers()
                .foregroundStyle(value > ConnThreshold.warn ? .connWarn : .connInk)
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
        }
        .frame(width: 44)
    }
}
