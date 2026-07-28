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
    private let percent: Double?
    private let minWidth: CGFloat

    /// - Parameters:
    ///   - percent: 原始负载百分比（0…100 语境，越界会被 clamp，不要求调用方
    ///     先手动归一化）。`nil` 表示尚无采样数据——真实场景是「运行中但还
    ///     没收到第一批指标」（如刚发现的主机、刚启动的容器），此时只画
    ///     灰轨道，不露出任何彩色头部。**不是**给「已停止」这类状态用的：
    ///     已停止的容器（见 `ContainerCard`）根本不渲染这块视图，不依赖
    ///     `nil` 分支来隐藏指标。
    ///   - minWidth: 有数据时的最小可见宽度，避免极小值看不见。
    public init(percent: Double?, minWidth: CGFloat) {
        self.percent = percent
        self.minWidth = minWidth
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.connTrack)
                if let fraction = Self.fraction(ofPercent: percent) {
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

    /// 把原始百分比归一化并 clamp 到 0…1；`nil` 保持 `nil`（代表无数据）。
    ///
    /// 抽成静态纯函数是因为 `min(max(x / 100, 0), 1)` 这段归一化此前在
    /// `HealthCard`/`HostOverviewView`（两处）/`ContainerCard` 各写了一遍——
    /// 收进组件内部后，这是唯一还写它的地方，脱离 SwiftUI 即可单测。
    static func fraction(ofPercent percent: Double?) -> Double? {
        guard let percent else { return nil }
        return min(max(percent / 100, 0), 1)
    }
}

#Preview("ConnLoadBar · 深色") {
    VStack(spacing: 12) {
        ConnLoadBar(percent: 0, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: 20, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: 60, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: 94, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: 100, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: nil, minWidth: 3).frame(height: 4)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("ConnLoadBar · 浅色") {
    VStack(spacing: 12) {
        ConnLoadBar(percent: 0, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: 20, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: 60, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: 94, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: 100, minWidth: 4).frame(height: 6)
        ConnLoadBar(percent: nil, minWidth: 3).frame(height: 4)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
