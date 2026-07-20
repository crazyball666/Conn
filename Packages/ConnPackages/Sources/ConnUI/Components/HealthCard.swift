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
        case .ok: "正常"
        case .warn: "警告"
        case .crit: "故障"
        case .offline: "离线"
        case .unknown: "未知"
        }
    }

    /// 是否为需要左侧红条警示的异常态。
    var isCritical: Bool {
        self == .crit || self == .offline
    }
}

/// 主机健康卡（仪表盘 S1 的主角）。
///
/// 设计规范 §5：Surface 底 + 16pt 连续圆角 + 顶边微光；左上主机名 + 地址（mono），
/// 右上状态点 + 文字；下方 CPU/内存/磁盘三迷你条，**各用指标专属色**；
/// 故障态整卡左侧 3pt 红色描边条。
///
/// 无障碍（设计规范 §7）：整卡聚合朗读为「web-01，正常，CPU 32%，内存 61%，磁盘 48%」。
public struct HealthCard: View {
    /// 卡片所需的展示数据。由 Feature 层从 `Host` + 最新 `MetricSample` 组装。
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

        public init(
            id: String,
            name: String,
            address: String,
            status: ConnHealthStatus,
            cpu: Double? = nil,
            memory: Double? = nil,
            disk: Double? = nil,
            issue: String? = nil
        ) {
            self.id = id
            self.name = name
            self.address = address
            self.status = status
            self.cpu = cpu
            self.memory = memory
            self.disk = disk
            self.issue = issue
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
                Text(model.name)
                    .font(.connHeadline)
                    .foregroundStyle(.connInk)
                Text(model.address)
                    .font(.connData())
                    .foregroundStyle(.connMuted)
            }
            Spacer(minLength: ConnSpacing.xs)
            StatusPill(model.status.label, semantic: model.status.pillSemantic)
        }
    }

    private var metricBars: some View {
        HStack(spacing: ConnSpacing.xs) {
            MiniMetricBar(label: "CPU", value: model.cpu, tint: .connAccent)
            MiniMetricBar(label: "内存", value: model.memory, tint: .connInfo)
            MiniMetricBar(label: "磁盘", value: model.disk, tint: .connDisk)
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
        var parts = ["\(model.name)，\(model.status.label)"]
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
                        .fill(barColor)
                        .frame(width: geometry.size.width * fraction)
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
}

#Preview("HealthCard · 深色") {
    VStack(spacing: ConnSpacing.stackGap) {
        HealthCard(.init(
            id: "1", name: "web-01", address: "root@10.0.0.1",
            status: .ok, cpu: 32, memory: 61, disk: 48
        )) {}
        HealthCard(.init(
            id: "2", name: "db-master", address: "root@10.0.0.2",
            status: .warn, cpu: 94, memory: 71, disk: 78
        )) {}
        HealthCard(.init(
            id: "3", name: "cache-01", address: "root@10.0.0.3",
            status: .crit, issue: "连接超时：22 端口无响应"
        )) {}
        HealthCard(.init(
            id: "4", name: "新主机", address: "root@10.0.0.4", status: .unknown
        )) {}
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}

#Preview("HealthCard · 浅色") {
    VStack(spacing: ConnSpacing.stackGap) {
        HealthCard(.init(
            id: "1", name: "web-01", address: "root@10.0.0.1",
            status: .ok, cpu: 32, memory: 61, disk: 48
        )) {}
        HealthCard(.init(
            id: "3", name: "cache-01", address: "root@10.0.0.3",
            status: .crit, issue: "连接超时：22 端口无响应"
        )) {}
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.light)
}
