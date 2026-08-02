import Charts
import ConnUI
import SwiftUI

/// 一条趋势序列（颜色 + 采样值）。
struct TrendSeries: Identifiable {
    let id: String
    let color: Color
    let values: [Double]
}

/// 指标趋势折线图。
///
/// - 单序列 → 默认填充面积 + 折线，也可仅显示折线；
/// - 多序列（网络上下行、IO 读写、各 CPU 核）→ 多条折线；
/// - `stacked` → 多条堆叠面积（如内存 已用/缓存/空闲 占比堆到 100%）。
///
/// X 轴隐藏（纯趋势），Y 轴留 3 档刻度，标签由 `yFormat` 定制。
struct MetricTrendChart: View {
    let series: [TrendSeries]
    let yDomain: ClosedRange<Double>
    var yFormat: (Double) -> String = { "\(Int($0))" }
    var stacked: Bool = false
    /// CPU 分类即使只剩一项也保持多线图语义，不使用面积填充。
    var fillsSingleSeries: Bool = true
    /// 图表需要有足够的垂直空间来读趋势，避免压缩成只有一条细线的装饰。
    var height: CGFloat = 132

    private var isSingle: Bool { series.count == 1 }

    var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(Array(line.values.enumerated()), id: \.offset) { index, value in
                    if stacked {
                        AreaMark(x: .value("t", index), y: .value("v", value))
                            .foregroundStyle(by: .value("type", line.id))
                            .interpolationMethod(.monotone)
                    } else if isSingle, fillsSingleSeries {
                        AreaMark(x: .value("t", index), y: .value("v", value))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [line.color.opacity(0.22), line.color.opacity(0.01)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)
                        singleLine(line, index: index, value: value)
                    } else {
                        LineMark(x: .value("t", index), y: .value("v", value), series: .value("s", line.id))
                            .foregroundStyle(line.color)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.id), range: series.map { $0.color.opacity(0.82) })
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
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
        .background(Color.connBg.opacity(0.26), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(height: height)
    }

    private func singleLine(_ line: TrendSeries, index: Int, value: Double) -> some ChartContent {
        LineMark(x: .value("t", index), y: .value("v", value))
            .foregroundStyle(line.color)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
    }
}
