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
}

/// 主机健康卡（服务器页 S1 的主角）。
///
/// 紧凑单行指标带：CPU/内存/磁盘 三枚小环（环心百分比、环下绝对量），
/// 网络/IO 各一列 ↑↓。**标题备注优先**；运行时长与负载缩进卡头右上。
/// **卡片高度恒定**：指标带始终占位，加载中盖 spinner、失败盖错误文案，
/// 加载成功淡出蒙层显示数据——不再「加载后突然变高」。故障态左侧 3pt 红条。
public struct HealthCard: View {
    /// 采集加载态：加载中 / 已加载 / 失败（带原因）。
    public enum LoadState: Sendable, Equatable {
        case loading
        case loaded
        case failed(String)
    }

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
        public let cpu: Double?
        public let memory: Double?
        public let disk: Double?
        public let coresText: String
        public let memTotalText: String
        public let diskTotalText: String
        public let net: Flow?
        public let io: Flow?
        public let uptimeText: String?
        public let loadText: String?
        /// 加载态：驱动指标带的 spinner / 错误蒙层。
        public let loadState: LoadState
        /// 用户备注（便于记忆）。有则作为卡片主标题优先显示。
        public let note: String?
        /// 采集进行中——右上角胶囊转圈。
        public let isBusy: Bool
        /// 正在重连：胶囊改显「重连中」并转蓝，与已认定的「连接失败」区分开。
        public let isReconnecting: Bool

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
            loadState: LoadState = .loaded,
            note: String? = nil,
            isBusy: Bool = false,
            isReconnecting: Bool = false
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
            self.loadState = loadState
            self.note = note
            self.isBusy = isBusy
            self.isReconnecting = isReconnecting
        }

        /// 卡片主标题：备注优先（用户的记忆锚点），否则用名称/地址。
        var title: String {
            if let note, !note.trimmingCharacters(in: .whitespaces).isEmpty { return note }
            return name
        }
    }

    private let model: Model
    private let onTap: () -> Void

    // 尺寸：环偏小、弧偏粗（圆润），环内/环下文字偏小，与标题层次协调。
    private let ringDiameter: CGFloat = 40
    private let ringStroke: CGFloat = 5.5

    public init(_ model: Model, onTap: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(Color.connLine).frame(height: 0.5).padding(.vertical, ConnSpacing.sm)
                bandArea
            }
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.connData(.caption2))
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: ConnSpacing.xs)
            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(pillText, semantic: pillSemantic, isBusy: model.isBusy)
                if model.uptimeText != nil || model.loadText != nil {
                    headerMeta
                }
            }
        }
    }

    /// 重连中时盖掉状态文案——「重连中」比「正常/故障」更贴近此刻发生的事。
    /// 常规采集**不改文案**，只转圈：每 30s 把「正常」换成「刷新中」会让状态区
    /// 一直跳，反而更吵。
    private var pillText: String {
        model.isReconnecting ? L("重连中") : model.status.label
    }

    private var pillSemantic: StatusPill.Semantic {
        model.isReconnecting ? .info : model.status.pillSemantic
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

    // MARK: - 指标带（恒定高度 + 加载/错误蒙层）

    /// 指标带始终参与布局（撑住高度）；未加载时以透明度隐藏，叠加骨架微光 / 错误。
    private var bandArea: some View {
        ZStack {
            metricBand.opacity(isLoaded ? 1 : 0)
            loadingSkeleton.opacity(isLoading ? 1 : 0)
            errorView.opacity(isFailed ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.25), value: model.loadState)
    }

    // MARK: - 加载骨架（微光扫过，镜像真实指标带布局）

    private var loadingSkeleton: some View {
        HStack(alignment: .top, spacing: ConnSpacing.xs) {
            skeletonRing
            skeletonRing
            skeletonRing
            skeletonColumn
            skeletonColumn
        }
        .shimmering()
    }

    private var skeletonRing: some View {
        VStack(spacing: 4) {
            skeletonBar(width: 22)
            Circle().stroke(Color.connTrack, lineWidth: ringStroke)
                .frame(width: ringDiameter, height: ringDiameter)
            skeletonBar(width: 30)
        }
        .frame(maxWidth: .infinity)
    }

    private var skeletonColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            skeletonBar(width: 28)
            skeletonBar(width: 46)
            skeletonBar(width: 38)
            skeletonBar(width: 46)
            skeletonBar(width: 38)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func skeletonBar(width: CGFloat) -> some View {
        Capsule().fill(Color.connTrack).frame(width: width, height: 7)
    }

    private var errorView: some View {
        VStack(spacing: 4) {
            Image(systemName: "wifi.slash").font(.system(size: 15)).foregroundStyle(.connCrit)
            Text(errorMessage)
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, ConnSpacing.sm)
    }

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
                Circle().stroke(Color.connTrack, lineWidth: ringStroke)
                Circle().trim(from: 0, to: fraction(value))
                    .stroke(ringColor(value, tint), style: StrokeStyle(lineWidth: ringStroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: ringColor(value, tint).opacity(0.3), radius: 2)
                    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: value)
                Text(value.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .connTabularNumbers()
                    .foregroundStyle(.connInk)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: ringDiameter, height: ringDiameter)
            Text(sub)
                .font(.system(size: 10, design: .monospaced))
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

    // MARK: - 派生

    private var isLoaded: Bool { model.loadState == .loaded }
    private var isLoading: Bool { model.loadState == .loading }
    private var isFailed: Bool {
        if case .failed = model.loadState { return true }
        return false
    }

    private var errorMessage: String {
        if case .failed(let message) = model.loadState { return message }
        return ""
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
        Self.accessibilityDescription(for: model)
    }

    /// 拼装无障碍口播文案。抽成 `static` 纯函数以便脱离 SwiftUI 单测
    /// （与 `StatusPill.busySymbol(reduceMotion:)` 同一模式）。入参用 `Model`
    /// 整体传入而非拆成一堆标量——`Model` 本就是不依赖 SwiftUI 的纯数据结构，
    /// 拆参数只会撞上 `function_parameter_count` 的 lint 上限。
    ///
    /// `isReconnecting`/`isBusy` 与 `loadState` 本是两套独立维度，原实现各自
    /// 判断要不要念一遍「采集中…」。但 `isBusy == true && loadState == .loading`
    /// 是每台主机首次采集必经的状态（`MonitorScheduler.attempt` 对无读数的主机
    /// 恒置 `.collecting`，`.loading` 的条件正是 `metrics == nil`），两个分支
    /// 会同时命中，念成「采集中…，采集中…」。这里把「是否要念一次采集中」合并
    /// 成单一判断，下面 `switch` 的 `.loading` 分支不再重复 append。
    ///
    /// 顺序/措辞：
    /// - 重连中优先于「采集中…」——「重连中」是更具体的状态（连接层面出了问题
    ///   在重试），比泛泛的「采集中」更值得优先播报；二者结构上也不会与
    ///   `.loading` 同时出现（`isReconnecting` 只在已有读数时才置位，`.loading`
    ///   恰好要求无读数），不存在「重连中，采集中」堆叠的可能。
    /// - 已加载且仍在后台刷新（`isBusy` 为真、`loadState == .loaded`，例行轮询
    ///   而非首采）：先念「采集中…」再念读数——让用户先建立「这批数字可能马上
    ///   更新」的预期，再听具体数字；与首采时「先概述活动、再给细节」的顺序
    ///   一致，减少 VoiceOver 用户在不同状态间切换时的心智模型跳变。
    static func accessibilityDescription(for model: Model) -> String {
        var parts = ["\(model.title)，\(model.status.label)"]

        if model.isReconnecting {
            parts.append(L("重连中"))
        } else if model.isBusy || model.loadState == .loading {
            parts.append(L("采集中…"))
        }

        switch model.loadState {
        case .loading:
            break // 已在上面合并处理，避免重复念「采集中…」
        case .failed(let message):
            parts.append(message)
        case .loaded:
            if let cpu = model.cpu { parts.append("CPU \(Int(cpu))%") }
            if let memory = model.memory { parts.append("内存 \(Int(memory))%") }
            if let disk = model.disk { parts.append("磁盘 \(Int(disk))%") }
        }

        return parts.joined(separator: "，")
    }
}

/// 骨架微光：一束高光沿骨架形状横扫，循环往复（比系统菊花更「有设计感」）。
///
/// 高光用 `connInk` 半透明——浅色下是柔和暗扫、深色下是柔和亮扫，两主题皆可见。
/// 尊重「减弱动态效果」：开启时退化为静态骨架（去扫光）。
private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(
                            colors: [.clear, Color.connInk.opacity(0.14), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.45)
                        .offset(x: phase * width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    phase = 1.6
                }
            }
    }
}

private extension View {
    /// 给骨架加循环微光扫过效果。
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

#Preview("HealthCard · 深色") {
    let net = HealthCard.Flow(upRate: "455 B", upTotal: "539 M", downRate: "1.0 K", downTotal: "7.2 G")
    let io = HealthCard.Flow(upRate: "37 K", upTotal: "29 G", downRate: "0 B", downTotal: "939 M")
    return VStack(spacing: ConnSpacing.stackGap) {
        HealthCard(.init(
            id: "1", name: "38.147.173.228", address: "root@38.147.173.228:62256",
            status: .ok, cpu: 8, memory: 38, disk: 68,
            coresText: "2 核", memTotalText: "3.6 G", diskTotalText: "30 G",
            net: net, io: io, uptimeText: "15 天", loadText: "0.09", note: "hk"
        )) {}
        HealthCard(.init(
            id: "2", name: "loading-host", address: "root@10.0.0.9",
            status: .unknown, loadState: .loading
        )) {}
        HealthCard(.init(
            id: "3", name: "db-master", address: "root@10.0.0.2",
            status: .offline, loadState: .failed("连接超时：22 端口无响应")
        )) {}
        HealthCard(.init(
            id: "4", name: "reconnecting-host", address: "root@10.0.0.4",
            status: .ok, cpu: 12, memory: 40, disk: 55,
            isBusy: true, isReconnecting: true
        )) {}
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}
