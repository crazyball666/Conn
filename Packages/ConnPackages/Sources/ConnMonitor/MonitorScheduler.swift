import ConnKit
import ConnSSH
import Foundation
import Observation

/// 某主机当前的采集阶段。
///
/// 与 `metrics`/`errors` 正交：那两者说「有没有读数、是不是已判定故障」，
/// 本枚举说「此刻有没有在采、是不是在重新握手」。
public enum CollectPhase: Sendable, Equatable {
    /// 不在采集。
    case idle
    /// 本轮采集在飞行中，复用池中已有会话。
    case collecting
    /// 会话已被驱逐，本轮在重新握手。
    case reconnecting
}

/// 采集调度（技术实现方案 §4.3）。
///
/// 两种模式：仪表盘可见 → 每主机 30s、并发上限 4；单机详情 → 该主机 3s 高频。
/// 页面不可见即 `stop()`。用 `@MainActor @Observable` 与 App 既有 VM 模式一致，
/// SwiftUI 直接观测 `metrics`；网络 I/O 在 `ConnectionManager`/`MetricCollector`
/// 两个 actor 的挂起点离开主线程。
@MainActor
@Observable
public final class MonitorScheduler {
    /// 各主机最新采集结果，键为 `Host.id`。
    public private(set) var metrics: [String: HostMetrics] = [:]
    /// 各主机最近一次采集错误（面向用户的短诊断），成功则清空。
    public private(set) var errors: [String: String] = [:]
    /// 各主机当前采集阶段，键为 `Host.id`。驱动卡片右上角的转圈与「重连中」。
    public private(set) var phases: [String: CollectPhase] = [:]
    public private(set) var lastScanAt: Date?
    /// 详情轮询是否附带概览详情段（系统名/CPU 型号/TCP 重传/网卡）——仅「概览」段激活时置真。
    public var wantsExtended = false
    /// 详情轮询是否附带进程列表——仅「进程」段激活时置真（VM 控制）。概览/仪表盘不采进程。
    public var wantsProcesses = false

    private let connectionManager: ConnectionManager
    private let collector: MetricCollector
    private let now: () -> Date
    private var task: Task<Void, Never>?

    /// 调度代次。`stop()` 递增一次（`startDashboard`/`startDetail`/`resumeAfterBackground`
    /// 开头都会经过它），采集只有在「发起时的代次 == 当前代次」时才允许写回。
    ///
    /// **为什么不靠 `Task.isCancelled`（评审给的方案 a）**：
    /// - 协作式取消要求被取消方主动查询，而一轮采集全程挂在 `await` 上
    ///   （握手、exec）。回前台时轮询 Task 大概率刚从 `Task.sleep(interval)`
    ///   醒来进入 `scanOnce`，`stop()` 的 `cancel()` 追不上它，旧轮与新轮并行：
    ///   每台主机双倍握手、旧轮结尾把新轮的转圈提前熄掉、旧轮 `record()` 的
    ///   红叉盖掉新轮刚写好的成功读数——正是本分支要消灭的「闪一下连接失败」。
    /// - 更关键的是 `scanNow`（下拉刷新）根本不经过 `task`，它跑在调用方的
    ///   Task 上，`Task.isCancelled` 对它恒为 false，方案 a 完全够不着。
    ///
    /// 代次是**数据侧**的判据：旧轮即便跑完，也一个字节都写不进 `metrics`/
    /// `errors`/`phases`/`lastScanAt`，与它此刻停在哪个 `await` 无关。
    private var generation = 0

    /// 采集在飞行中的主机 id。同一主机同一时刻只允许一轮采集。
    ///
    /// 代次挡的是「跨代」的旧轮；下拉刷新（`scanNow`）与轮询是**同代**的两轮，
    /// 代次对它们都成立，仍会双倍握手、互相覆盖写回（一轮 `record()` 清空
    /// `metrics`，另一轮刚写好成功读数 → 卡片闪一下红）。用飞行中集合去重，
    /// 让后到的那一轮直接让位——它要的数据先到的那轮马上就会写进来。
    ///
    /// **前置条件**：依赖 `attempt` 里的 await 终会返回（`defer` 才有机会移除该 id）。
    /// 目前假引擎与 `session.exec(_:timeout:)` 都带超时；真 SSH 引擎接入后，
    /// `exec` 的超时必须真正生效——一次永不返回的 exec 会把该主机的 id 永久留在
    /// 集合里，此后所有轮次都对它让位，这台主机的采集永久停摆（UI 上表现为转圈不落）。
    private var inFlight: Set<String> = []

    /// 上次 `startDashboard` 的参数。回前台恢复时按原样重启。
    ///
    /// 用具名 struct 而非三元组：三元组会触发 SwiftLint `large_tuple`（上限 2 个成员）。
    private struct DashboardConfig {
        let hosts: [ConnKit.Host]
        let interval: Duration
        let concurrency: Int
    }
    private var dashboardConfig: DashboardConfig?

    public init(
        connectionManager: ConnectionManager,
        collector: MetricCollector = MetricCollector(),
        now: @escaping () -> Date = Date.init
    ) {
        self.connectionManager = connectionManager
        self.collector = collector
        self.now = now
    }

    // MARK: - 生命周期

    /// 仪表盘模式：轮询全部主机，每轮并发上限 `concurrency`，轮间隔 `interval`。
    ///
    /// 两处收敛，避免切 Tab / 返回列表时无条件重采：
    /// - **预热轮**（开头睡 2s 再采一次）只为首采点亮 CPU（使用率需两次采样差分）。
    ///   已有读数说明基线在，跳过。
    /// - **防抖**：距上次采集不足 5s 视为刚采过，本次连立即那轮也跳过。
    ///   `force` 用于回前台——那是明确要立刻重采的场景。
    public func startDashboard(
        hosts: [ConnKit.Host],
        interval: Duration = .seconds(30),
        concurrency: Int = 4,
        force: Bool = false
    ) {
        stop()
        dashboardConfig = DashboardConfig(hosts: hosts, interval: interval, concurrency: concurrency)
        // 预热判据按「逐主机」而非全局 `metrics.isEmpty`——CPU 使用率要两次采样差分，
        // 而基线本就是每主机一份（`MetricCollector.previousCPU[host.id]`）。全局判据下
        // 「已有 N 台在线时新增第 N+1 台」`metrics` 非空 → 不预热 → 新卡片的 CPU 环要
        // 挂满一个 interval（默认 30s）才点亮。
        //
        // 但只看 `metrics` 还不够：`record()` 判定故障时做的是 `metrics[host.id] = nil`，
        // 而 Swift 字典赋 nil **等于删键**——故障主机与「从没采过」在 `metrics` 里长得
        // 一模一样。于是只要用户有 1 台长期不可达的主机，`needsWarmUp` 就永久为真，
        // `isFresh` 永久为假，每次切回服务器页都是「立即一轮 + 2s 后预热轮」，两轮都对着
        // 死主机跑满连接超时——防抖整体失效，与本次收敛采集时机的目标正好相反。
        // 所以再看一眼 `errors`：只有「从没采出过读数、也还没被判定故障」的主机才需要
        // 预热轮点亮 CPU；已判定故障的主机不该让整页反复重采。
        let needsWarmUp = hosts.contains { metrics[$0.id] == nil && errors[$0.id] == nil }
        // 有主机缺基线时不防抖：否则「新增主机后 5s 内切走再切回」会把立即那轮
        // 也跳过，新卡片要挂着骨架一整个 interval。
        let isFresh = !force && !needsWarmUp
            && (lastScanAt.map { now().timeIntervalSince($0) < 5 } ?? false)
        let scanGeneration = generation

        task = Task { [weak self] in
            guard let self else { return }
            if !isFresh {
                await self.scanOnce(hosts: hosts, concurrency: concurrency, generation: scanGeneration)
                guard self.isCurrent(scanGeneration) else { return }
                self.lastScanAt = self.now()
                if needsWarmUp {
                    try? await Task.sleep(for: .seconds(2))
                    guard self.isCurrent(scanGeneration) else { return }
                    await self.scanOnce(hosts: hosts, concurrency: concurrency, generation: scanGeneration)
                    guard self.isCurrent(scanGeneration) else { return }
                    self.lastScanAt = self.now()
                }
            }
            // 先睡后采：否则 isFresh 跳过立即采集后会马上又采一轮，防抖失效。
            // 同时查取消：代次是数据侧判据，挡的是写回；`Task.isCancelled` 是控制侧的。
            // 今天两者总是同步推进（`cancel()` 只在 `stop()` 里出现且紧跟代次递增），
            // 但一旦将来有别的路径只取消 task 而不推进代次，被取消的 Task 里
            // `Task.sleep` 会立刻抛错返回 → `try?` 吞掉 → 循环空转成热循环，
            // 打满 CPU 并疯狂重采。加上这半个判据是零成本的保险。
            while self.isCurrent(scanGeneration) && !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard self.isCurrent(scanGeneration) else { return }
                await self.scanOnce(hosts: hosts, concurrency: concurrency, generation: scanGeneration)
                guard self.isCurrent(scanGeneration) else { return }
                self.lastScanAt = self.now()
            }
        }
    }

    /// 单机详情模式：只高频轮询这一台。每轮按 `wantsProcesses` 决定是否附带进程列表。
    public func startDetail(host: ConnKit.Host, interval: Duration = .seconds(3)) {
        stop()
        let scanGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            // 同时查取消，理由同 `startDashboard`：被取消的 Task 里 `try? await
            // Task.sleep` 立刻返回，只靠代次判据会退化成打满 CPU 的热循环。
            while self.isCurrent(scanGeneration) && !Task.isCancelled {
                await self.collectOne(
                    host, generation: scanGeneration,
                    includeExtended: self.wantsExtended, includeProcesses: self.wantsProcesses
                )
                guard self.isCurrent(scanGeneration) else { return }
                self.lastScanAt = self.now()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 立刻补采一次当前详情主机（切到概览/进程段时用——别等下一个轮询间隔才出详情/进程）。
    public func refreshDetail(host: ConnKit.Host) async {
        let scanGeneration = generation
        await collectOne(
            host, generation: scanGeneration,
            includeExtended: wantsExtended, includeProcesses: wantsProcesses
        )
        guard isCurrent(scanGeneration) else { return }
        lastScanAt = now()
    }

    /// 停止轮询（页面不可见 / 切走时调用）。
    ///
    /// **本方法即「仪表盘不再运行」这一不变量**：调用后 `dashboardConfig` 为 nil，
    /// `resumeAfterBackground` 随之完全 no-op（详见下方对连接池的说明）。
    /// 若将来需要「暂停但保留恢复配置」的语义，请另开入口，不要复用本方法——
    /// 保留配置会让回前台重新拉起轮询并 `invalidateAll()`，打死骑在同一条 SSH
    /// 连接上的终端 shell / 日志流 / sftp handle。
    public func stop() {
        task?.cancel()
        task = nil
        // 递增代次：已在飞行中的那一轮从此写不进任何状态。单靠 cancel() 拦不住它，
        // 它多半正挂在握手或 exec 的 await 上，取消信号到达时早已越过检查点。
        generation &+= 1
        // 轮询停了就没有任何一台在采集中，否则转圈会一直挂着。
        phases.removeAll()
        // 清掉恢复配置，把 `resumeAfterBackground` 的作用域精确收敛到
        // 「仪表盘此刻确实在跑」。
        //
        // 不清的话 `dashboardConfig` 从 App 启动（服务器是默认 Tab）起就永不为 nil，
        // `resumeAfterBackground` 的 guard 恒真，于是**任何**回前台都会
        // `invalidateAll()`。而 `ConnectionManager` 是全 App 唯一的连接池：终端的
        // 交互式 shell、日志的 `tail -f`、文件编辑器跨会话持有的 sftp handle 全都
        // 骑在同一条 SSH 连接上，关连接会把这些长命通道一起打死——用户开着终端
        // 切走 30s 再回来，界面就冻住且无报错。
        // `ServersView.onDisappear → stop()` 正是「仪表盘不可见」的既有信号；
        // 顺带也修掉「用户已切走 Tab 后回前台，却用陈旧配置把轮询重新拉起来」。
        dashboardConfig = nil
    }

    /// 发起时的代次是否仍是当前代次。为 false 说明这轮已被 `stop()` / 重启作废。
    private func isCurrent(_ scanGeneration: Int) -> Bool {
        generation == scanGeneration
    }

    /// 回前台恢复。
    ///
    /// - Parameter idleFor: 处于后台的时长（秒）。
    ///
    /// 后台超过 30s 时，池里的 socket 多半已被服务器 idle timeout 或系统回收——
    /// 主动驱逐并强制重采，比等下一个采集间隔（默认 30s）撞上死会话再自愈快得多。
    /// 不足 30s 则什么都不做：轮询 Task 随 App 恢复自然继续，就算会话真死了，
    /// `collectOne` 的同轮重试也会兜住。
    ///
    /// `dashboardConfig` 为 nil（仪表盘已 `stop()`）时同样什么都不做——
    /// `invalidateAll()` 关的是整条 SSH 连接，会连带打死骑在上面的终端 shell /
    /// 日志流 / sftp handle，只有「仪表盘此刻确实在跑」才值得付这个代价。
    public func resumeAfterBackground(idleFor: TimeInterval) async {
        guard idleFor > 30, let config = dashboardConfig else { return }
        await connectionManager.invalidateAll()
        startDashboard(
            hosts: config.hosts, interval: config.interval,
            concurrency: config.concurrency, force: true
        )
    }

    /// 手动触发一轮全量采集（下拉刷新）。
    public func scanNow(hosts: [ConnKit.Host], concurrency: Int = 4) async {
        let scanGeneration = generation
        await scanOnce(hosts: hosts, concurrency: concurrency, generation: scanGeneration)
        guard isCurrent(scanGeneration) else { return }
        lastScanAt = now()
    }

    // MARK: - 采集

    /// 一轮采集，滑动窗口维持至多 `concurrency` 个并发（TaskGroup 补位）。
    private func scanOnce(hosts: [ConnKit.Host], concurrency: Int, generation: Int) async {
        guard !hosts.isEmpty else { return }
        var iterator = hosts.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while running < max(1, concurrency), let host = iterator.next() {
                group.addTask { await self.collectOne(host, generation: generation) }
                running += 1
            }
            while await group.next() != nil {
                if let host = iterator.next() {
                    group.addTask { await self.collectOne(host, generation: generation) }
                }
            }
        }
    }

    /// 采一台。失败只记 `errors[host.id]`，不抛、不影响其他主机（方案 §4.3 验收）。
    /// 仪表盘轮询默认只取核心段；详情轮询按 `wantsExtended`/`wantsProcesses` 传入。
    ///
    /// **首次传输失败会立刻重握手重试一次**：死会话（App 在后台期间被服务器
    /// idle timeout 或系统回收）第一次使用必然失败，那不是故障，不该打扰用户。
    /// 重试期间 `phases` 为 `.reconnecting`，UI 显示「重连中」；重试仍失败才如实转红。
    private func collectOne(
        _ host: ConnKit.Host, generation scanGeneration: Int,
        includeExtended: Bool = false, includeProcesses: Bool = false
    ) async {
        // 作废的旧轮直接不跑；同一主机已有一轮在飞行中也让位（详见 `generation`/`inFlight`）。
        guard isCurrent(scanGeneration), !inFlight.contains(host.id) else { return }
        inFlight.insert(host.id)
        defer { inFlight.remove(host.id) }

        // 只有「本来有读数」的主机才享受这次宽限。首采失败直接如实报错；
        // 已判定故障的主机（metrics 已被清空）也不再重试，避免每轮双倍连接尝试。
        let allowsRetry = metrics[host.id] != nil

        if let error = await attempt(
            host, generation: scanGeneration,
            includeExtended: includeExtended, includeProcesses: includeProcesses
        ) {
            guard isCurrent(scanGeneration) else { return }
            if allowsRetry {
                if let retryError = await attempt(
                    host, generation: scanGeneration,
                    includeExtended: includeExtended, includeProcesses: includeProcesses
                ) {
                    guard isCurrent(scanGeneration) else { return }
                    record(retryError, for: host)
                }
            } else {
                record(error, for: host)
            }
        }
        // 作废的旧轮不许收圈：否则它会把新一轮刚点亮的转圈提前熄掉。
        guard isCurrent(scanGeneration) else { return }
        phases[host.id] = .idle
    }

    /// 一次采集尝试。
    ///
    /// 成功返回 nil；失败**先驱逐会话**（可能已死，下次尝试重新握手 → 断网后自愈）
    /// 再返回错误，但**不写 `errors`**——是否把它呈现为故障由 `collectOne` 决定。
    private func attempt(
        _ host: ConnKit.Host, generation scanGeneration: Int,
        includeExtended: Bool, includeProcesses: Bool
    ) async -> Error? {
        // 池里没有会话 = 本次要握手。首采（无读数）仍走骨架态，不算重连。
        let needsHandshake = await !connectionManager.hasPooledSession(for: host)
        // 越过 await 后代次可能已变（页面切走/回前台重启）。返回 nil 让调用方
        // 当作「无错可报」，它自己的 guard 会立刻收尾，不写任何状态。
        guard isCurrent(scanGeneration) else { return nil }
        phases[host.id] = (needsHandshake && metrics[host.id] != nil) ? .reconnecting : .collecting
        do {
            let session = try await connectionManager.session(for: host)
            let result = try await collector.collect(
                host: host, session: session,
                includeExtended: includeExtended, includeProcesses: includeProcesses
            )
            guard isCurrent(scanGeneration) else { return nil }
            // 本轮没采的段（切走的概览/进程段）沿用上次值，切回来不闪空/不重载。
            metrics[host.id] = result.carryingOver(
                metrics[host.id], keepExtended: !includeExtended, keepProcesses: !includeProcesses
            )
            errors[host.id] = nil
            return nil
        } catch {
            // 驱逐可能已死的会话，下次尝试重新握手 → 断网后自愈。
            // 这里只驱逐、不写 errors：一次传输失败还不等于主机故障。
            await connectionManager.invalidate(host: host)
            return error
        }
    }

    /// 认定为故障：写错误文案，并清掉过期实时指标——主机立即显示离线/未知，
    /// 而不是一直挂着旧的绿色读数。
    private func record(_ error: Error, for host: ConnKit.Host) {
        errors[host.id] = error.friendlyDiagnosis
        metrics[host.id] = nil
    }
}
