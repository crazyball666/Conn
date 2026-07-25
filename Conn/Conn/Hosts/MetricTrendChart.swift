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
/// 单序列（CPU%/内存%）→ 填充面积 + 折线；多序列（网络上下行、IO 读写）→ 多条折线。
/// X 轴隐藏（纯趋势），Y 轴留 3 档刻度，标签由 `yFormat` 定制（百分比或字节速率）。
struct MetricTrendChart: View {
    let series: [TrendSeries]
    let yDomain: ClosedRange<Double>
    var yFormat: (Double) -> String = { "\(Int($0))" }
    var height: CGFloat = 58

    private var isSingle: Bool { series.count == 1 }

    var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(Array(line.values.enumerated()), id: \.offset) { index, value in
                    if isSingle {
                        AreaMark(x: .value("t", index), y: .value("v", value))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [line.color.opacity(0.22), line.color.opacity(0.01)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("t", index), y: .value("v", value), series: .value("s", line.id))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.connLine)
                if let doubleValue = value.as(Double.self) {
                    AxisValueLabel {
                        Text(yFormat(doubleValue))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.connDim)
                    }
                }
            }
        }
        .frame(height: height)
    }
}
