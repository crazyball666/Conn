import ConnKit
import ConnMonitor
import ConnUI
import SwiftUI

/// 图表颜色是数据语义的一部分，固定后不会因主题或系统强调色变化而改变含义。
private enum HostChartPalette {
    static let cpuUser = Color(.sRGB, red: 0.145, green: 0.388, blue: 0.922, opacity: 1)
    static let cpuSystem = Color(.sRGB, red: 0.863, green: 0.149, blue: 0.149, opacity: 1)
    static let cpuWait = Color(.sRGB, red: 0.792, green: 0.541, blue: 0.016, opacity: 1)
    static let cpuIdle = Color(.sRGB, red: 0.486, green: 0.518, blue: 0.580, opacity: 1)
    static let cpuNice = Color(.sRGB, red: 0.086, green: 0.639, blue: 0.290, opacity: 1)
    static let cpuHardInterrupt = Color(.sRGB, red: 0.576, green: 0.200, blue: 0.918, opacity: 1)
    static let cpuSoftInterrupt = Color(.sRGB, red: 0.859, green: 0.153, blue: 0.467, opacity: 1)
    static let cpuSteal = Color(.sRGB, red: 0.051, green: 0.580, blue: 0.533, opacity: 1)

    static let memoryUsed = Color(.sRGB, red: 0.89, green: 0.35, blue: 0.39, opacity: 1)
    static let memoryCache = Color(.sRGB, red: 0.86, green: 0.60, blue: 0.08, opacity: 1)
    static let memoryFree = Color(.sRGB, red: 0.12, green: 0.64, blue: 0.34, opacity: 1)
    static let swap = Color(.sRGB, red: 0.57, green: 0.36, blue: 0.88, opacity: 1)
    static let diskRead = Color(.sRGB, red: 0.145, green: 0.388, blue: 0.922, opacity: 1)
    static let diskWrite = Color(.sRGB, red: 0.918, green: 0.345, blue: 0.047, opacity: 1)
    static let networkDown = Color(.sRGB, red: 0.05, green: 0.57, blue: 0.78, opacity: 1)
    static let networkUp = Color(.sRGB, red: 0.12, green: 0.64, blue: 0.34, opacity: 1)
}

/// 单机概览：分块（系统 / 负载 / CPU / 内存 / 磁盘 / 网络 / 进程）。
/// CPU 显示各核折线、内存显示 RAM 堆叠占比与 Swap 用量摘要、磁盘与磁盘 IO 合并一块。
struct HostOverviewView<Header: View>: View {
    let viewModel: HostOverviewViewModel
    private let header: Header
    @State private var cpuVisibility = CPUChartVisibility()

    init(viewModel: HostOverviewViewModel, @ViewBuilder header: () -> Header) {
        self.viewModel = viewModel
        self.header = header()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                header
                if let error = viewModel.errorText, viewModel.latest == nil {
                    ConnBanner(error, systemImage: "wifi.slash")
                }
                if let message = viewModel.capabilityMessage {
                    ConnBanner(message, systemImage: "exclamationmark.triangle")
                }
                systemCard
                cpuSection
                memorySection
                diskSection
                networkSection
            }
            .padding(.bottom, ConnSpacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .onChange(of: viewModel.latest) { _, _ in viewModel.record() }
        // 仅概览页可见时才让脚本带详情段（系统名/CPU 型号/TCP 重传/网卡）——其它页面不采。
        .onAppear { viewModel.setOverviewSegmentActive(true) }
        .onDisappear { viewModel.setOverviewSegmentActive(false) }
    }

    // MARK: - 系统（系统信息 + 负载合并一块）

    /// 顶行：操作系统（左上角）+ 运行时长（右上角），无 key 字段；
    /// 分隔线下方接负载 1/5/15 分钟三列。
    private var systemCard: some View {
        section(L("系统")) {
            HStack(alignment: .firstTextBaseline, spacing: ConnSpacing.sm) {
                Text(latest?.osName ?? "—")
                    .font(.connData(.caption2)).fontWeight(.semibold).foregroundStyle(.connMuted)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: ConnSpacing.sm)
                Text(MetricFormat.uptime(latest?.uptimeSeconds))
                    .font(.connData(.caption2)).fontWeight(.semibold).connTabularNumbers().foregroundStyle(.connMuted)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            sectionDivider
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
            cpuUsageChart
            cpuPerCoreBars
        }
    }

    // MARK: - 内存（RAM 三段堆叠占比 + Swap 明细）

    private var memorySection: some View {
        section(L("内存")) {
            percentHeader(
                latest?.mem,
                detail: MetricFormat.pair(used: latest?.memUsedBytes, total: latest?.memTotalBytes)
            )
            chartOrPlaceholder(memSeries, domain: 0 ... 100, yFormat: { "\(Int($0))" }, stacked: true)
            HStack(spacing: 0) {
                breakdownColumn(L("已用"), MetricFormat.bytes(latest?.memUsedBytes), HostChartPalette.memoryUsed)
                breakdownColumn(L("缓存"), MetricFormat.bytes(latest?.memBuffersCache), HostChartPalette.memoryCache)
                breakdownColumn(L("空闲"), MetricFormat.bytes(latest?.memFree), HostChartPalette.memoryFree)
            }
            swapSummary
        }
    }

    private var memSeries: [TrendSeries] {
        [
            TrendSeries(id: L("已用"), color: HostChartPalette.memoryUsed, values: viewModel.memUsedHistory),
            TrendSeries(id: L("缓存"), color: HostChartPalette.memoryCache, values: viewModel.memCacheHistory),
            TrendSeries(id: L("空闲"), color: HostChartPalette.memoryFree, values: viewModel.memFreeHistory)
        ]
    }

    private var swapSummary: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            sectionDivider
            HStack(alignment: .firstTextBaseline, spacing: ConnSpacing.sm) {
                HStack(spacing: 4) {
                    Circle().fill(HostChartPalette.swap).frame(width: 7, height: 7)
                    Text(L("Swap")).font(.connData(.caption2)).foregroundStyle(.connMuted)
                }
                Spacer()
                Text(swapDetail)
                    .font(.connData(.caption2)).connTabularNumbers().foregroundStyle(.connMuted)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            if let percent = swapPercent {
                HStack(spacing: ConnSpacing.sm) {
                    ConnLoadBar(percent: percent, minWidth: 4)
                        .frame(height: 6)
                    Text("\(Int(percent))%")
                        .font(.connData(.caption2)).connTabularNumbers().foregroundStyle(.connDim)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    private var swapPercent: Double? {
        guard let total = latest?.swapTotalBytes, total > 0,
              let used = latest?.swapUsedBytes else { return nil }
        return min(100, max(0, used / total * 100))
    }

    private var swapDetail: String {
        guard let total = latest?.swapTotalBytes else { return "—" }
        guard total > 0 else { return L("未启用") }
        return MetricFormat.pair(used: latest?.swapUsedBytes, total: total)
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
            ConnLoadBar(percent: latest?.disk, minWidth: 6)
                .frame(height: 8)
            Rectangle().fill(Color.connLine).frame(height: 0.5).padding(.vertical, 2)
            chartHeader(
                legend: [(L("读"), HostChartPalette.diskRead), (L("写"), HostChartPalette.diskWrite)],
                totals: "\(L("读")) \(MetricFormat.bytes(latest?.ioReadBytes))  \(L("写")) \(MetricFormat.bytes(latest?.ioWriteBytes))"
            )
            chartOrPlaceholder(rateSeries(
                down: viewModel.ioReadHistory, downColor: HostChartPalette.diskRead,
                up: viewModel.ioWriteHistory, upColor: HostChartPalette.diskWrite
            ))
        }
    }

    // MARK: - 网络（双向折线 + 右上角累计量）

    private var networkSection: some View {
        section(L("网络")) {
            chartHeader(
                legend: [(L("下行"), HostChartPalette.networkDown), (L("上行"), HostChartPalette.networkUp)],
                totals: "↓ \(MetricFormat.bytes(latest?.netRx))  ↑ \(MetricFormat.bytes(latest?.netTx))"
            )
            chartOrPlaceholder(rateSeries(
                down: viewModel.netRxHistory, downColor: HostChartPalette.networkDown,
                up: viewModel.netTxHistory, upColor: HostChartPalette.networkUp
            ))
            if let tcp = latest?.tcp {
                sectionDivider
                tcpGrid(tcp)
            }
            if let interfaces = latest?.interfaces, !interfaces.isEmpty {
                sectionDivider
                interfaceList(interfaces)
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle().fill(Color.connLine).frame(height: 0.5).padding(.vertical, 2)
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
        stacked: Bool = false,
        fillsSingleSeries: Bool = true,
        height: CGFloat = 132
    ) -> some View {
        let hasData = series.contains { $0.values.count >= 2 }
        let resolved = domain ?? autoDomain(series)
        return Group {
            if hasData {
                MetricTrendChart(
                    series: series,
                    yDomain: resolved,
                    yFormat: yFormat,
                    stacked: stacked,
                    fillsSingleSeries: fillsSingleSeries,
                    height: height
                )
            } else {
                Text(L("采集中…"))
                    .font(.connFootnote).foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity).frame(height: height)
            }
        }
    }

    private func autoDomain(_ series: [TrendSeries]) -> ClosedRange<Double> {
        let peak = series.flatMap { $0.values }.max() ?? 0
        return 0 ... max(peak * 1.25, 1024)
    }

    // MARK: - 派生 / 绑定

    private var latest: HostMetrics? { viewModel.latest }
}

// MARK: - CPU 明细（各类占比网格 + 使用率趋势 + 各核占用条）

/// CPU 各类时间占比的一格（标签 + 值 + 颜色）。
private struct CPUStatItem: Identifiable {
    let metric: CPUChartMetric
    let label: String
    let value: Double?
    let color: Color
    var id: CPUChartMetric { metric }
}

private extension HostOverviewView {
    var cpuBreakdownGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
            spacing: ConnSpacing.sm
        ) {
            ForEach(cpuBreakdownItems) { item in
                let visible = cpuVisibility.contains(item.metric)
                Button {
                    cpuVisibility.toggle(item.metric)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(visible ? item.color : Color.connDim)
                                .frame(width: 6, height: 6)
                            Text(item.label)
                                .font(.connData(.caption2))
                                .foregroundStyle(visible ? item.color : Color.connDim)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(item.value.map { String(format: "%.1f%%", $0) } ?? "—")
                            .font(.connData(.footnote))
                            .connTabularNumbers()
                            .foregroundStyle(visible ? Color.connInk : Color.connDim)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cpu.metric.\(item.metric.rawValue)")
                .accessibilityLabel(
                    String(
                        format: visible ? L("%@，已显示") : L("%@，已隐藏"),
                        item.label
                    )
                )
                .accessibilityValue(visible ? "visible" : "hidden")
                .accessibilityHint(L("双击切换图表折线"))
            }
        }
        .sensoryFeedback(.selection, trigger: cpuVisibility)
    }

    var cpuBreakdownItems: [CPUStatItem] {
        let breakdown = viewModel.latest?.cpuBreakdown
        return [
            CPUStatItem(metric: .user, label: L("用户"), value: breakdown?.user, color: HostChartPalette.cpuUser),
            CPUStatItem(metric: .system, label: L("系统"), value: breakdown?.system, color: HostChartPalette.cpuSystem),
            CPUStatItem(metric: .iowait, label: L("IO 等待"), value: breakdown?.iowait, color: HostChartPalette.cpuWait),
            CPUStatItem(metric: .idle, label: L("空闲"), value: breakdown?.idle, color: HostChartPalette.cpuIdle),
            CPUStatItem(metric: .nice, label: L("nice"), value: breakdown?.nice, color: HostChartPalette.cpuNice),
            CPUStatItem(metric: .irq, label: L("硬中断"), value: breakdown?.irq, color: HostChartPalette.cpuHardInterrupt),
            CPUStatItem(metric: .softirq, label: L("软中断"), value: breakdown?.softirq, color: HostChartPalette.cpuSoftInterrupt),
            CPUStatItem(metric: .steal, label: L("抢占"), value: breakdown?.steal, color: HostChartPalette.cpuSteal)
        ]
    }

    /// CPU 八类时间占比趋势；上方指标格同时作为图例和显示开关。
    var cpuUsageChart: some View {
        let series = cpuBreakdownItems.compactMap { item -> TrendSeries? in
            guard cpuVisibility.contains(item.metric) else { return nil }
            return TrendSeries(
                id: item.label,
                color: item.color,
                values: viewModel.cpuCategoryHistory[item.metric]
            )
        }
        return Group {
            if series.isEmpty {
                Text(L("请选择指标"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .accessibilityIdentifier("cpu.chart.empty")
            } else {
                chartOrPlaceholder(
                    series,
                    domain: 0 ... 100,
                    yFormat: { "\(Int($0))%" },
                    fillsSingleSeries: false
                )
            }
        }
    }

    var cpuPerCoreBars: some View {
        let cores = viewModel.latest?.cpuPerCore ?? []
        return VStack(spacing: 6) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, usage in
                HStack(spacing: ConnSpacing.sm) {
                    Text("CPU\(index)")
                        .font(.connData(.caption2)).foregroundStyle(.connMuted)
                        .frame(width: 42, alignment: .leading)
                    ConnLoadBar(percent: usage, minWidth: 4)
                        .frame(height: 6)
                    Text("\(Int(usage))%")
                        .font(.connData(.caption2)).connTabularNumbers().foregroundStyle(.connInk)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - 网络明细（TCP 统计 + 各网卡）

private extension HostOverviewView {
    func tcpGrid(_ tcp: TCPStats) -> some View {
        HStack(spacing: 0) {
            tcpCell(L("重传率"), String(format: "%.1f%%", tcp.retransRate),
                    tcp.retransRate > 2 ? .connWarn : .connInk)
            tcpCell(L("主动建连"), tcp.activeOpens.formatted(), .connInk)
            tcpCell(L("被动建连"), tcp.passiveOpens.formatted(), .connInk)
            tcpCell(L("建连失败"), tcp.attemptFails.formatted(),
                    tcp.attemptFails > 0 ? .connWarn : .connInk)
        }
    }

    func tcpCell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            Text(value).font(.connData(.footnote)).connTabularNumbers().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func interfaceList(_ interfaces: [NetInterface]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(interfaces.enumerated()), id: \.element.id) { index, iface in
                if index > 0 {
                    Rectangle().fill(Color.connLine).frame(height: 0.5)
                }
                interfaceRow(iface)
            }
        }
    }

    func interfaceRow(_ iface: NetInterface) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(iface.name).font(.connData(.footnote)).foregroundStyle(.connInk).lineLimit(1)
                Spacer()
                if let ip = iface.ip {
                    Text(ip).font(.connData(.caption2)).foregroundStyle(.connMuted)
                }
            }
            HStack(spacing: ConnSpacing.md) {
                Text("↑ \(MetricFormat.rate(iface.txRate))")
                    .font(.connData(.caption2)).foregroundStyle(.connGood)
                Text("↓ \(MetricFormat.rate(iface.rxRate))")
                    .font(.connData(.caption2)).foregroundStyle(.connInfo)
                Spacer()
                Text("↑\(MetricFormat.bytes(iface.txTotal)) ↓\(MetricFormat.bytes(iface.rxTotal))")
                    .font(.connData(.caption2)).foregroundStyle(.connDim)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, ConnSpacing.xs)
    }
}
