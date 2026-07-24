import SwiftUI

/// 主机健康状态的**展示层**表示。
///
/// 刻意与 `ConnKit.Host.HealthStatus` 分离：设计系统不依赖领域模型
/// （设计规范 §9「组件一律 stateless」），由 Feature 层负责映射。
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

    var isCritical: Bool { self == .crit || self == .offline }
}

/// 主机健康卡（服务器页 S1 的主角）。
///
/// 紧凑单行指标带（参考竞品密排）：CPU/内存/磁盘 三枚小环（环心百分比、环下绝对量），
/// 网络/IO 各一列 ↑↓（速率在上、总量在下）。**标题备注优先**（用户的记忆锚点），
/// 运行时长与负载缩进卡头右上。故障态整卡左侧 3pt 红条。
public struct HealthCard: View {
    /// 网络/IO 的双向读数（已格式化）：上/下行的速率与累计。
    public struct Flow: Sendable, Equatable {
        public let upRate: String
        public let upTotal: String
        public let downRate: String
        public let downTotal: String
        public init(upRate: String, upTotal: String, downRate: String, downTotal: String) {
            self.upRate = upRate
            self.upTotal = upTotal
            self.downRate = downRate
            self.downTotal = downTotal
        }
    }

    /// 卡片所需的展示数据。由 Feature 层从 `Host` + 最新 `HostMetrics` 组装。
    public struct Model: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let address: String
        public let status: ConnHealthStatus
        /// 环形百分比 0–100，nil 显示「—」。
        public let cpu: Double?
        public let memory: Double?
        public let disk: Double?
        /// 环下绝对量（已格式化）：核心数 / 内存总量 / 磁盘总量。
        public let coresText: String
        public let memTotalText: String
        public let diskTotalText: String
        public let net: Flow?
        public let io: Flow?
        /// 卡头右上：运行时长与 1 分钟负载（已格式化，缺则 nil）。
        public let uptimeText: String?
        public let loadText: String?
        /// 故障态一行处置提示。
        public let issue: String?
        /// 用户备注（便于记忆）。有则作为卡片主标题优先显示。
        public let note: String?

        public init(
            id: String,
            name: String,
            address: String,
            status: ConnHealthStatus,
            cpu: Double? = nil,
            memory: Double? = nil,
            disk: Double? = nil,
            coresText: String = "—",
            memTotalText: String = "—",
            diskTotalText: String = "—",
            net: Flow? = nil,
            io: Flow? = nil,
            uptimeText: String? = nil,
            loadText: String? = nil,
            issue: String? = nil,
            note: String? = nil
        ) {
            self.id = id
            self.name = name
            self.address = address
            self.status = status
            self.cpu = cpu
            self.memory = memory
            self.disk = disk
            self.coresText = coresText
            self.memTotalText = memTotalText
            self.diskTotalText = diskTotalText
            self.net = net
            self.io = io
            self.uptimeText = uptimeText
            self.loadText = loadText
            self.issue = issue
            self.note = note
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
                    Rectangle().fill(Color.connLine).frame(height: 0.5).padding(.vertical, ConnSpacing.sm)
                    metricBand
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

    // MARK: - 卡头

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
            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(model.status.label, semantic: model.status.pillSemantic)
                if model.uptimeText != nil || model.loadText != nil {
                    headerMeta
                }
            }
        }
    }

    private var headerMeta: some View {
        HStack(spacing: ConnSpacing.xs) {
            if let uptime = model.uptimeText {
                metaChip("power", uptime)
            }
            if let load = model.loadText {
                metaChip("gauge.with.dots.needle.33percent", load)
            }
        }
        .font(.connData(.caption2))
        .foregroundStyle(.connMuted)
    }

    private func metaChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).connTabularNumbers()
        }
    }

    // MARK: - 指标带

    private var metricBand: some View {
        HStack(alignment: .top, spacing: ConnSpacing.xs) {
            ring(L("CPU"), value: model.cpu, sub: model.coresText, tint: .connAccent)
            ring(L("内存"), value: model.memory, sub: model.memTotalText, tint: .connInfo)
            ring(L("磁盘"), value: model.disk, sub: model.diskTotalText, tint: .connDisk)
            flowColumn(L("网络"), model.net)
            flowColumn("IO", model.io)
        }
    }

    private func ring(_ label: String, value: Double?, sub: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            ZStack {
                Circle().stroke(Color.connTrack, lineWidth: 4)
                Circle().trim(from: 0, to: fraction(value))
                    .stroke(ringColor(value, tint), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: ringColor(value, tint).opacity(0.35), radius: 2)
                    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: value)
                Text(value.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .connTabularNumbers()
                    .foregroundStyle(.connInk)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 46, height: 46)
            Text(sub)
                .font(.connData(.caption2))
                .foregroundStyle(.connMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func flowColumn(_ label: String, _ flow: Flow?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            flowRow("arrow.up", rate: flow?.upRate, total: flow?.upTotal)
            flowRow("arrow.down", rate: flow?.downRate, total: flow?.downTotal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flowRow(_ icon: String, rate: String?, total: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.connMuted)
                Text(rate ?? "—")
                    .font(.connData(.caption2)).connTabularNumbers().foregroundStyle(.connInk)
            }
            Text(total ?? "—")
                .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.connDim)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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

    // MARK: - 派生

    private var hasMetrics: Bool {
        model.cpu != nil || model.memory != nil || model.disk != nil || model.net != nil || model.io != nil
    }

    private func fraction(_ value: Double?) -> CGFloat {
        guard let value else { return 0 }
        return min(max(value / 100, 0), 1)
    }

    private func ringColor(_ value: Double?, _ tint: Color) -> Color {
        guard let value else { return .connTrack }
        if value > ConnThreshold.crit { return .connCrit }
        if value > ConnThreshold.warn { return .connWarn }
        return tint
    }

    private var accessibilityDescription: String {
        var parts = ["\(model.title)，\(model.status.label)"]
        if let cpu = model.cpu { parts.append("CPU \(Int(cpu))%") }
        if let memory = model.memory { parts.append("内存 \(Int(memory))%") }
        if let disk = model.disk { parts.append("磁盘 \(Int(disk))%") }
        if let issue = model.issue { parts.append(issue) }
        return parts.joined(separator: "，")
    }
}

#Preview("HealthCard · 深色") {
    let net = HealthCard.Flow(upRate: "455 B", upTotal: "539 M", downRate: "1.0 K", downTotal: "7.2 G")
    let io = HealthCard.Flow(upRate: "37 K", upTotal: "29 G", downRate: "0 B", downTotal: "939 M")
    return VStack(spacing: ConnSpacing.stackGap) {
        HealthCard(.init(
            id: "1", name: "38.147.173.228", address: "root@38.147.173.228:62256",
            status: .ok, cpu: 3, memory: 38, disk: 68,
            coresText: "2 核", memTotalText: "3.6 G", diskTotalText: "30 G",
            net: net, io: io, uptimeText: "15 天", loadText: "0.10", note: "hk"
        )) {}
        HealthCard(.init(
            id: "2", name: "db-master", address: "root@10.0.0.2",
            status: .crit, issue: "连接超时：22 端口无响应"
        )) {}
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}
