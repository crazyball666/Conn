import SwiftUI

/// 指标环（单机详情 S3 的核心读数）。
///
/// 设计规范 §5：58pt 环形、7pt 线宽、中心大数字用 rounded + 等宽数字位。
/// 超阈值统一切 warn/crit——**指标专属色只在正常区间使用**（§2）。
public struct MetricGauge: View {
    private let label: String
    private let value: Double?
    private let tint: Color

    /// - Parameters:
    ///   - label: 指标名，如「CPU」「内存」「磁盘」。
    ///   - value: 百分比 0–100。nil 表示尚无采样，环显示为空槽。
    ///   - tint: 正常区间的指标专属色（CPU→accent、内存→info、磁盘→disk）。
    public init(label: String, value: Double?, tint: Color) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    public var body: some View {
        VStack(spacing: 6) {
            ring
            Text(label)
                .font(.connData(.caption2))
                .foregroundStyle(.connMuted)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .connSurface(cornerRadius: ConnRadius.card)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(label) \(Int($0))%" } ?? "\(label) \(L("无数据"))")
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.connTrack, lineWidth: ConnSize.gaugeLineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    arcColor,
                    style: StrokeStyle(lineWidth: ConnSize.gaugeLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            valueText
        }
        .frame(width: ConnSize.gaugeDiameter, height: ConnSize.gaugeDiameter)
    }

    private var valueText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value.map { "\(Int($0))" } ?? "—")
                .font(.connGaugeValue())
                .connTabularNumbers()
                .foregroundStyle(.connInk)
            if value != nil {
                Text("%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.connMuted)
            }
        }
        .contentTransition(.numericText())
    }

    private var fraction: CGFloat {
        guard let value else { return 0 }
        return min(max(value / 100, 0), 1)
    }

    private var arcColor: Color {
        guard let value else { return .connTrack }
        if value > ConnThreshold.crit {
            return .connCrit
        }
        if value > ConnThreshold.warn {
            return .connWarn
        }
        return tint
    }
}

#Preview("MetricGauge · 深色") {
    VStack(spacing: ConnSpacing.md) {
        HStack(spacing: ConnSpacing.xs) {
            MetricGauge(label: "CPU", value: 32, tint: .connAccent)
            MetricGauge(label: "内存", value: 61, tint: .connInfo)
            MetricGauge(label: "磁盘", value: 48, tint: .connDisk)
        }
        HStack(spacing: ConnSpacing.xs) {
            MetricGauge(label: "警戒", value: 85, tint: .connAccent)
            MetricGauge(label: "危险", value: 96, tint: .connInfo)
            MetricGauge(label: "无数据", value: nil, tint: .connDisk)
        }
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("MetricGauge · 浅色") {
    HStack(spacing: ConnSpacing.xs) {
        MetricGauge(label: "CPU", value: 32, tint: .connAccent)
        MetricGauge(label: "内存", value: 61, tint: .connInfo)
        MetricGauge(label: "磁盘", value: 48, tint: .connDisk)
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
