import SwiftUI

/// 负载条：一条走负载色标（低=绿、高=红）的水平进度条。
///
/// **为什么要有这个组件**：渐变必须按「整条轨道」铺开再用 `mask` 裁到当前值。
/// 若写成 `.fill(渐变).frame(width: 已填充宽度)`，SwiftUI 会把整条渐变压缩进
/// 那一小段，于是 20% 与 94% 都从绿扫到红，「值越高越红」的信息完全丢失——
/// 而这个错误在高载时看着完全正常，只有低载才暴露，单测也覆盖不到。
/// 每核 CPU 条与 Docker 容器 CPU/内存条原先各写了一份逐字重复的实现，
/// 把它收在一处，将来新增条形图直接复用，不会重犯。
public struct ConnLoadBar: View {
    private let fraction: Double?
    private let minWidth: CGFloat

    /// - Parameters:
    ///   - fraction: 已归一化到 0…1 的负载。`nil` 表示无数据，此时只画灰轨道，
    ///     不能露出任何彩色头部——调用方（如已停止的容器）依赖这一点隐藏指标。
    ///   - minWidth: 有数据时的最小可见宽度，避免极小值看不见。
    public init(fraction: Double?, minWidth: CGFloat) {
        self.fraction = fraction
        self.minWidth = minWidth
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.connTrack)
                if let fraction {
                    Capsule()
                        .fill(LinearGradient(
                            gradient: ConnLoadScale.gradient,
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geometry.size.width)
                        .mask(alignment: .leading) {
                            Capsule()
                                .frame(width: max(minWidth, geometry.size.width * CGFloat(fraction)))
                        }
                }
            }
        }
    }
}

#Preview("ConnLoadBar · 深色") {
    VStack(spacing: 12) {
        ConnLoadBar(fraction: 0.2, minWidth: 4).frame(height: 6)
        ConnLoadBar(fraction: 0.6, minWidth: 4).frame(height: 6)
        ConnLoadBar(fraction: 0.94, minWidth: 4).frame(height: 6)
        ConnLoadBar(fraction: nil, minWidth: 3).frame(height: 4)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("ConnLoadBar · 浅色") {
    VStack(spacing: 12) {
        ConnLoadBar(fraction: 0.2, minWidth: 4).frame(height: 6)
        ConnLoadBar(fraction: 0.6, minWidth: 4).frame(height: 6)
        ConnLoadBar(fraction: 0.94, minWidth: 4).frame(height: 6)
        ConnLoadBar(fraction: nil, minWidth: 3).frame(height: 4)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
