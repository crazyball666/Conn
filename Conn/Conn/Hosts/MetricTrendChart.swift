import Charts
import ConnUI
import SwiftUI

/// 一次指标采样的稳定坐标。
///
/// 序号不会因为滚动窗口裁剪而重置；这让 Swift Charts 只移动新增/移出的点，
/// 不会把整条曲线误认为一组全新的数据。
struct TrendSample: Identifiable, Equatable, Sendable {
    let sequence: Int
    let value: Double

    var id: Int { sequence }
}

/// 趋势图可视窗口策略。
///
/// 屏幕上始终显示 40 个采样槽位，但数据层多保留一个已经/即将位于左边界外的点。
/// 新采样到达时，旧点可以先随视口完整移出，再在下一轮从屏外裁剪，避免面积路径因
/// 边界点被提前删除而闪烁。
enum TrendViewport {
    static let visibleSampleCount = 40
    static let retainedSampleCount = visibleSampleCount + 1

    static func xDomain(endingAt sequence: Double) -> ClosedRange<Double> {
        let visibleSpan = Double(visibleSampleCount - 1)
        return (sequence - visibleSpan) ... sequence
    }
}

/// 一条趋势序列（颜色 + 采样值）。
struct TrendSeries: Identifiable {
    let id: String
    let color: Color
    let samples: [TrendSample]
}

/// 多序列面积的纵向组合方式。
enum TrendAreaStacking: Sendable {
    /// 像网络上下行一样累计堆积，各层厚度代表该系列的值。
    case cumulative
    /// 每个系列都从 0 绘制到自己的真实值，不做纵向求和。
    case independent

    var markMethod: MarkStackingMethod {
        switch self {
        case .cumulative: .standard
        case .independent: .unstacked
        }
    }
}

/// 指标趋势折线图。
///
/// - 单序列 → 一层渐变堆叠面积；
/// - 多序列（CPU 分类、内存、网络上下行、IO 读写）→ 多层渐变堆叠面积；
/// - `stacked == false` 仅保留给未来需要普通折线的场景。
///
/// X 轴隐藏（纯趋势），Y 轴留 5 档刻度，标签由 `yFormat` 定制。
struct MetricTrendChart: View {
    let series: [TrendSeries]
    let yDomain: ClosedRange<Double>
    var yFormat: (Double) -> String = { "\(Int($0))" }
    var stacked: Bool = true
    /// CPU 分类要显示各自真实百分比；网络/IO 则保留累计堆积语义。
    var areaStacking: TrendAreaStacking = .cumulative
    /// 仅在关闭堆叠时控制单序列是否附带面积填充。
    var fillsSingleSeries: Bool = true
    /// 图表需要有足够的垂直空间来读趋势，避免压缩成只有一条细线的装饰。
    var height: CGFloat = 132
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 数据先进入屏外，随后只推动视口；不再对整张 Chart 的数据树做隐式动画。
    @State private var viewportEnd: Double?

    private var isSingle: Bool { series.count == 1 }
    private var latestSequence: Int? {
        series.flatMap(\.samples).map(\.sequence).max()
    }
    /// Double 域可以连续插值；Int 域只能整格跳变，无法产生真正平滑的水平位移。
    private var xDomain: ClosedRange<Double> {
        TrendViewport.xDomain(endingAt: viewportEnd ?? Double(latestSequence ?? 0))
    }

    private var yAxisValues: [Double] {
        Self.axisValues(in: yDomain)
    }

    /// Swift Charts 的 `desiredCount` 只是建议，常会把 5 自动收缩成 3。
    /// 显式给出五个等距值，保证所有复用本组件的指标图刻度数量一致。
    static func axisValues(in domain: ClosedRange<Double>) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return [domain.lowerBound] }
        return Array(0 ... 4).map { domain.lowerBound + span * Double($0) / 4 }
    }

    var body: some View {
        Chart {
            // 面积层始终按输入顺序稳定绘制，不再随每轮峰值变化重排图层。
            ForEach(series) { line in
                ForEach(line.samples) { sample in
                    if stacked {
                        AreaMark(
                            x: .value("t", Double(sample.sequence)),
                            y: .value("v", sample.value),
                            stacking: areaStacking.markMethod
                        )
                            .foregroundStyle(by: .value("type", line.id))
                            .interpolationMethod(.monotone)
                    } else if isSingle, fillsSingleSeries {
                        AreaMark(x: .value("t", Double(sample.sequence)), y: .value("v", sample.value))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [line.color.opacity(0.22), line.color.opacity(0.01)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)
                        singleLine(line, sample: sample)
                    } else {
                        LineMark(
                            x: .value("t", Double(sample.sequence)),
                            y: .value("v", sample.value),
                            series: .value("s", line.id)
                        )
                            .foregroundStyle(chartStyle(for: line.id))
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.id), mapping: chartStyle(for:))
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain, range: .plotDimension(startPadding: 4, endPadding: 8))
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: yAxisValues) { value in
                AxisGridLine().foregroundStyle(Color.connLine.opacity(0.8))
                if let doubleValue = value.as(Double.self) {
                    AxisValueLabel {
                        Text(yFormat(doubleValue))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.connDim)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .chartPlotStyle { plotArea in
            plotArea.clipShape(Rectangle())
        }
        .onAppear {
            if viewportEnd == nil, let latestSequence {
                viewportEnd = Double(latestSequence)
            }
        }
        .onChange(of: latestSequence) { _, newSequence in
            guard let newSequence else { return }
            moveViewport(to: newSequence)
        }
        .background(Color.connBg.opacity(0.26), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(height: height)
    }

    private func moveViewport(to sequence: Int) {
        let target = Double(sequence)
        guard let current = viewportEnd else {
            viewportEnd = target
            return
        }
        guard current != target else { return }

        if reduceMotion || target < current {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewportEnd = target
            }
        } else {
            withAnimation(ConnMotion.chartUpdate) {
                viewportEnd = target
            }
        }
    }

    private func singleLine(_ line: TrendSeries, sample: TrendSample) -> some ChartContent {
        LineMark(x: .value("t", Double(sample.sequence)), y: .value("v", sample.value))
            .foregroundStyle(chartStyle(for: line.id))
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
    }

    /// 按数据系列映射同一基色的纵向渐变。不同系列仍保持稳定的基色语义，
    /// 只是从图表顶部到底部逐步降低明度和透明度，让面积和折线都有层次。
    private func chartStyle(for id: String) -> AnyShapeStyle {
        guard let line = series.first(where: { $0.id == id }) else {
            return AnyShapeStyle(Color.clear)
        }
        return AnyShapeStyle(LinearGradient(
            colors: [
                line.color.opacity(0.96),
                line.color.opacity(0.68),
                line.color.opacity(0.34),
            ],
            startPoint: .top,
            endPoint: .bottom
        ))
    }
}
