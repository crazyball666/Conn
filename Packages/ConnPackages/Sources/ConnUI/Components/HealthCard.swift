import SwiftUI

/// 主机健康卡（服务器页 S1 的主角）。
///
/// 紧凑单行指标带：CPU/内存/磁盘 三枚小环（环心百分比、环下绝对量），
/// 网络/IO 各一列 ↑↓；运行时长与负载缩进卡头右上。
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
        /// 指标健康严重度，仅用于健康统计，不参与右上角 SSH 连接胶囊。
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
        /// SSH 连接阶段：驱动右上角胶囊的连接/重连文案与转圈。
        public let connectionPhase: ConnConnectionPhase
        /// 后台指标采集阶段。与 SSH 连接阶段独立，采集不会改变状态文案。
        public let collectPhase: ConnCollectPhase

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
            connectionPhase: ConnConnectionPhase,
            collectPhase: ConnCollectPhase = .idle
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
            self.connectionPhase = connectionPhase
            self.collectPhase = collectPhase
        }

        /// 主机名称是卡片唯一的主标题。
        var title: String { name }
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
        .accessibilityIdentifier("servers.host.\(model.id)")
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
                StatusPill(
                    statusPillText,
                    semantic: statusPillSemantic,
                    isBusy: isStatusBusy
                )
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
            ring(L("CPU"), value: model.cpu, sub: model.coresText)
            ring(L("内存"), value: model.memory, sub: model.memTotalText)
            ring(L("磁盘"), value: model.disk, sub: model.diskTotalText)
            flowColumn(L("网络"), model.net)
            flowColumn("IO", model.io)
        }
    }

    /// 单个指标环。
    ///
    /// 颜色不再区分指标，而是**沿弧长扫过负载色标**——环上每个角度位置对应
    /// 那个位置的负载值，弧尖的颜色即当前值。`Circle().trim` 与 `AngularGradient`
    /// 都从 3 点钟起算，又被同一个 `rotationEffect(-90°)` 一起旋转，所以角度
    /// 与负载值天然对齐，不需要额外换算。
    private func ring(_ label: String, value: Double?, sub: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            ZStack {
                Circle().stroke(Color.connTrack, lineWidth: ringStroke)
                Circle().trim(from: 0, to: fraction(value))
                    .stroke(
                        arcStyle(for: value),
                        style: StrokeStyle(lineWidth: ringStroke, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
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

    /// 无数据时是灰轨道色，有数据时是负载渐变。
    ///
    /// 笔帽故意选**平头 `.butt`**，而不是观感更圆润的 `.round`：圆头笔帽会在
    /// 弧的起点之前，沿路径多外伸半个笔宽——这段外伸区，恰好与「负载接近
    /// 满载」时弧尖所在的角度扇区，是同一块地方。`AngularGradient` 是循环
    /// 取色的一整条色标，同一角度只能对应色标上唯一的一个位置：这里既要
    /// 是弧起点该有的绿（低载起点不能顶红点），又要是弧尖该有的红（高载
    /// 弧尖不能糊成绿），两者互斥，是几何上的死结，不是渐变参数能调开的
    /// （曾经试过把渐变整体平移、或把跨度撑到 360° 以上兼顾两头，前者会
    /// 让 97.5% 以上的高载弧尖被误判为绿色、后者会在跨度重叠的那一小段
    /// 出现归属二义、动画过渡期间红点间歇性复现）。平头没有任何外伸，
    /// 弧严格只覆盖 `[0°, 360°·负载]`，与 `AngularGradient` 显式声明铺满的
    /// `[0°, 360°]` 精确一一对应，起点即色标起点、弧尖即当前负载对应的
    /// 颜色，不需要再借助偏移去回避这个冲突。`startAngle`/`endAngle` 显式写
    /// 出而非依赖两者同为默认值 `.zero` 时的隐式整圈行为——上面这段论证
    /// 完全建立在跨度恰好是 `[0°, 360°]` 之上，这个不变量理应出现在代码里。
    private func arcStyle(for value: Double?) -> AnyShapeStyle {
        guard value != nil else { return AnyShapeStyle(Color.connTrack) }
        return AnyShapeStyle(AngularGradient(
            gradient: ConnLoadScale.gradient, center: .center,
            startAngle: .degrees(0), endAngle: .degrees(360)
        ))
    }

    private func flowColumn(_ label: String, _ flow: Flow?) -> some View {
        VStack(alignment: .center, spacing: 3) {
            Text(label).font(.connData(.caption2)).foregroundStyle(.connMuted)
            flowRow("arrow.up", rate: flow?.upRate, total: flow?.upTotal)
            flowRow("arrow.down", rate: flow?.downRate, total: flow?.downTotal)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func flowRow(_ icon: String, rate: String?, total: String?) -> some View {
        VStack(alignment: .center, spacing: 0) {
            HStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.connMuted)
                Text(rate ?? "—")
                    .font(.connData(.caption2)).connTabularNumbers().foregroundStyle(.connInk)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            Text(total ?? "—")
                .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.connDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    // MARK: - 派生

    private var isLoaded: Bool { model.loadState == .loaded }
    private var isLoading: Bool { model.loadState == .loading }
    private var statusPillText: String {
        model.connectionPhase.pillText
    }

    private var statusPillSemantic: StatusPill.Semantic {
        model.connectionPhase.pillSemantic
    }

    private var isStatusBusy: Bool { model.connectionPhase.isBusy }
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

    private var accessibilityDescription: String {
        Self.accessibilityDescription(for: model)
    }

    /// 拼装无障碍口播文案。抽成 `static` 纯函数以便脱离 SwiftUI 单测
    /// （与 `StatusPill.busySymbol(reduceMotion:)` 同一模式）。入参用 `Model`
    /// 整体传入而非拆成一堆标量——`Model` 本就是不依赖 SwiftUI 的纯数据结构，
    /// 拆参数只会撞上 `function_parameter_count` 的 lint 上限。
    ///
    /// `connectionPhase` 与 `collectPhase` 是两套独立维度：前者只播报 SSH
    /// 连接/重连，后者只表示指标刷新。两者可能同时出现，但不能因此把
    /// 「CPU 基线尚未完成」播报成「连接中」。采集过程完全后台静默。
    ///
    /// 顺序/措辞：
    /// - 重连中优先于健康状态——「重连中」是更具体的连接层状态。
    static func accessibilityDescription(for model: Model) -> String {
        let statusText = model.connectionPhase.pillText
        var parts = ["\(model.title)，\(statusText)"]

        switch model.loadState {
        case .loading:
            break
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
            net: net, io: io, uptimeText: "15 天", loadText: "0.09",
            connectionPhase: .connected
        )) {}
        HealthCard(.init(
            id: "2", name: "loading-host", address: "root@10.0.0.9",
            status: .unknown, loadState: .loading, connectionPhase: .connecting
        )) {}
        HealthCard(.init(
            id: "3", name: "db-master", address: "root@10.0.0.2",
            status: .offline, loadState: .failed("连接超时：22 端口无响应"), connectionPhase: .failed
        )) {}
        HealthCard(.init(
            id: "4", name: "reconnecting-host", address: "root@10.0.0.4",
            status: .ok, cpu: 12, memory: 40, disk: 55,
            connectionPhase: .reconnecting, collectPhase: .reconnecting
        )) {}
        // 边界样本（负载色标验收面）：nil 只画灰轨道；>92 三环全部封顶红；
        // 正好 100% 会在 12 点方向出现绿红硬相接——AngularGradient 套闭合
        // 形状的固有表现，是预期的，不是要修的 bug，样本目的正是让它可见。
        HealthCard(.init(
            id: "5", name: "no-metrics-host", address: "root@10.0.0.7",
            status: .ok, coresText: "—", memTotalText: "—", diskTotalText: "—",
            connectionPhase: .connected
        )) {}
        HealthCard(.init(
            id: "6", name: "over-92-host", address: "root@10.0.0.8",
            status: .warn, cpu: 95, memory: 97, disk: 99,
            coresText: "4 核", memTotalText: "7.6 G", diskTotalText: "39.2 G",
            connectionPhase: .connected
        )) {}
        HealthCard(.init(
            id: "7", name: "maxed-out-host", address: "root@10.0.0.9",
            status: .crit, cpu: 100, memory: 100, disk: 100,
            coresText: "4 核", memTotalText: "7.6 G", diskTotalText: "39.2 G",
            connectionPhase: .connected
        )) {}
    }
    .padding(ConnSpacing.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.connBg)
    .preferredColorScheme(.dark)
}
