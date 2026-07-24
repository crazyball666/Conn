import SwiftUI

/// 主机健康状态的**展示层**表示。
///
/// 刻意与 `ConnKit.Host.HealthStatus` 分离：设计系统不依赖领域模型
/// （设计规范 §9「组件一律 stateless」），由 Feature 层负责映射。
/// 这让 ConnUI 可独立预览与测试，也避免 UI 层被领域模型的演化牵动。
public enum ConnHealthStatus: Sendable, CaseIterable {
    case ok, warn, crit, offline, unknown

    var pillSemantic: StatusPill.Semantic {
        switch self {
        case .ok: .good
        case .warn: .warn
        case .crit, .offline: .crit
        case .unknown: .off
        }
    }

    var label: String {
        switch self {
        case .ok: L("正常")
        case .warn: L("警告")
        case .crit: L("故障")
        case .offline: L("离线")
        case .unknown: L("未知")
        }
    }

    /// 是否为需要左侧红条警示的异常态。
    var isCritical: Bool {
        self == .crit || self == .offline
    }
}

/// 主机健康卡（服务器页 S1 的主角）。
///
/// 设计规范 §5：Surface 底 + 16pt 连续圆角 + 顶边微光。**标题为备注优先**
/// （用户的记忆锚点，如「hk」），无备注才用名称/地址；地址退居 mono 副标题。
/// 下方 CPU/内存/磁盘三迷你条 + 二列指标网格（核数/运行/内存/磁盘/网络/IO）。
/// 故障态整卡左侧 3pt 红色描边条。
///
/// 展示口径的字节/速率格式化在 Feature 层完成后以字符串传入（`stats`），
/// 保持设计系统无格式化/领域逻辑。
public struct HealthCard: View {
    /// 卡片二级指标网格里的一格：标签 + 已格式化的值。
    public struct Stat: Identifiable, Sendable, Equatable {
        public let label: String
        public let value: String
        public var id: String { label }
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// 卡片所需的展示数据。由 Feature 层从 `Host` + 最新 `HostMetrics` 组装。
    public struct Model: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let address: String
        public let status: ConnHealthStatus
        /// CPU 使用率 0–100。nil 表示尚无采样。
        public let cpu: Double?
        public let memory: Double?
        public let disk: Double?
        /// 故障态下的一行处置提示，如「22 端口无响应」。
        public let issue: String?
        /// 用户备注（便于记忆）。有则作为卡片主标题优先显示。
        public let note: String?
        /// 二级指标网格（已格式化）。为空则不显示网格。
        public let stats: [Stat]

        public init(
            id: String,
            name: String,
            address: String,
            status: ConnHealthStatus,
            cpu: Double? = nil,
            memory: Double? = nil,
            disk: Double? = nil,
            issue: String? = nil,
            note: String? = nil,
            stats: [Stat] = []
        ) {
            self.id = id
            self.name = name
            self.address = address
            self.status = status
            self.cpu = cpu
            self.memory = memory
            self.disk = disk
            self.issue = issue
            self.note = note
            self.stats = stats
        }

        /// 卡片主标题：备注优先（用户的记忆锚点），否则用名称/地址。
        var title: String {
            if let note, !note.trimmingCharacters(in: .whitespaces).isEmpty { return note }
            return name
        }
    }

    private let model: Model
    private let onTap: () -> Void

    public init(_ model: Model, onTap: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let issue = model.issue {
                    Text(issue)
                        .font(.connSubheadline)
                        .foregroundStyle(.connMuted)
                        .padding(.top, ConnSpacing.xs)
                }
                if hasMetrics {
                    metricBars.padding(.top, 10)
                }
                if !model.stats.isEmpty {
                    Rectangle().fill(Color.connLine).frame(height: 0.5)
                        .padding(.top, ConnSpacing.sm)
                    statGrid.padding(.top, ConnSpacing.sm)
                }
            }
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) { critEdge }
            .connSurface(cornerRadius: ConnRadius.card)
        }
        .buttonStyle(ConnPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - 组成部分

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.connHeadline)
                    .foregroundStyle(.connInk)
                    .lineLimit(1)
                Text(model.address)
                    .font(.connData())
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: ConnSpacing.xs)
            StatusPill(model.status.label, semantic: model.status.pillSemantic)
        }
    }

    private var metricBars: some View {
        HStack(spacing: ConnSpacing.xs) {
            MiniMetricBar(label: "CPU", value: model.cpu, tint: .connAccent)
            MiniMetricBar(label: L("内存"), value: model.memory, tint: .connInfo)
            MiniMetricBar(label: L("磁盘"), value: model.disk, tint: .connDisk)
        }
    }

    /// 二级指标网格：两列，每格标签在上、值在下（mono、等宽数字）。
    private var statGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: ConnSpacing.sm, alignment: .leading),
                GridItem(.flexible(), spacing: ConnSpacing.sm, alignment: .leading)
            ],
            alignment: .leading,
            spacing: ConnSpacing.sm
        ) {
            ForEach(model.stats) { stat in
                VStack(alignment: .leading, spacing: 1) {
                    Text(stat.label)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                    Text(stat.value)
                        .font(.connData(.footnote))
                        .connTabularNumbers()
                        .foregroundStyle(.connInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 故障态左侧 3pt 红条。
    @ViewBuilder
    private var critEdge: some View {
        if model.status.isCritical {
            UnevenRoundedRectangle(
                topLeadingRadius: ConnRadius.card,
                bottomLeadingRadius: ConnRadius.card,
                style: .continuous
            )
            .fill(Color.connCrit)
            .frame(width: ConnSize.critEdgeWidth)
        }
    }

    // MARK: - 派生值

    private var hasMetrics: Bool {
        model.cpu != nil || model.memory != nil || model.disk != nil
    }

    private var accessibilityDescription: String {
        var parts = ["\(model.title)，\(model.status.label)"]
        if let cpu = model.cpu {
            parts.append("CPU \(Int(cpu))%")
        }
        if let memory = model.memory {
            parts.append("内存 \(Int(memory))%")
        }
        if let disk = model.disk {
            parts.append("磁盘 \(Int(disk))%")
        }
        if let issue = model.issue {
            parts.append(issue)
        }
        return parts.joined(separator: "，")
    }
}

/// HealthCard 底部的迷你指标条。
///
/// 超阈值时统一切 warn/crit——指标专属色只在正常区间使用（设计规范 §2）。
struct MiniMetricBar: View {
    let label: String
    let value: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(label)
                Spacer(minLength: 2)
                Text(value.map { "\(Int($0))%" } ?? "—")
                    .connTabularNumbers()
            }
            .font(.connData(.caption2))
            .foregroundStyle(.connMuted)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.connTrack)
                    Capsule()
                        .fill(barGradient)
                        .frame(width: max(ConnSize.miniBarHeight, geometry.size.width * fraction))
                        .shadow(color: barColor.opacity(0.5), radius: 2, y: 0)
                        // 指标一变,条子平滑补到新长度(不弹跳)。
                        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: value)
                }
            }
            .frame(height: ConnSize.miniBarHeight)
        }
    }

    private var fraction: CGFloat {
        guard let value else { return 0 }
        return min(max(value / 100, 0), 1)
    }

    private var barColor: Color {
        guard let value else { return .connTrack }
        if value > ConnThreshold.crit {
            return .connCrit
        }
        if value > ConnThreshold.warn {
            return .connWarn
        }
        return tint
    }

    /// 条子沿长度方向的微渐变——头亮尾淡,增加质感。
    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [barColor, barColor.opacity(0.62)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

#Preview("HealthCard · 深色") {
    let demoStats: [HealthCard.Stat] = [
        .init("核心", "2 核"), .init("运行", "10 天 2 小时"),
        .init("内存", "3.0 / 8.0 GB"), .init("磁盘", "27 / 40 GB"),
        .init("网络 ↓", "60 KB/s · 5.5 MB"), .init("网络 ↑", "36 KB/s · 3.3 MB"),
        .init("IO 读", "835 KB/s · 19 GB"), .init("IO 写", "439 KB/s · 8 GB")
    ]
    return VStack(spacing: ConnSpacing.stackGap) {
        HealthCard(.init(
            id: "1", name: "38.147.173.228", address: "root@38.147.173.228:62256",
            status: .ok, cpu: 10, memory: 38, disk: 68, note: "hk", stats: demoStats
        )) {}
        HealthCard(.init(
            id: "3", name: "cache-01", address: "root@10.0.0.3",
            status: .crit, issue: "连接超时：22 端口无响应"
        )) {}
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("HealthCard · 浅色") {
    HealthCard(.init(
        id: "1", name: "web-01", address: "root@10.0.0.1",
        status: .ok, cpu: 32, memory: 61, disk: 48, note: "主站入口"
    )) {}
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
