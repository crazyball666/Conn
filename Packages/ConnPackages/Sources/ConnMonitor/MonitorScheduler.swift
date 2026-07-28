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
    /// 首采只拿到内存/磁盘（CPU 需两次差分）。为不让 CPU 环空等一整个间隔，
    /// 开头做一次 2s 预热采集把 CPU 尽快点亮，之后才进入常规间隔。
    public func startDashboard(hosts: [ConnKit.Host], interval: Duration = .seconds(30), concurrency: Int = 4) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            await self.scanOnce(hosts: hosts, concurrency: concurrency)
            self.lastScanAt = self.now()
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self.scanOnce(hosts: hosts, concurrency: concurrency)
                self.lastScanAt = self.now()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 单机详情模式：只高频轮询这一台。每轮按 `wantsProcesses` 决定是否附带进程列表。
    public func startDetail(host: ConnKit.Host, interval: Duration = .seconds(3)) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.collectOne(host, includeExtended: self.wantsExtended, includeProcesses: self.wantsProcesses)
                self.lastScanAt = self.now()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 立刻补采一次当前详情主机（切到概览/进程段时用——别等下一个轮询间隔才出详情/进程）。
    public func refreshDetail(host: ConnKit.Host) async {
        await collectOne(host, includeExtended: wantsExtended, includeProcesses: wantsProcesses)
        lastScanAt = now()
    }

    /// 停止轮询（页面不可见 / 切走时调用）。
    public func stop() {
        task?.cancel()
        task = nil
        // 轮询停了就没有任何一台在采集中，否则转圈会一直挂着。
        phases.removeAll()
    }

    /// 手动触发一轮全量采集（下拉刷新）。
    public func scanNow(hosts: [ConnKit.Host], concurrency: Int = 4) async {
        await scanOnce(hosts: hosts, concurrency: concurrency)
        lastScanAt = now()
    }

    // MARK: - 采集

    /// 一轮采集，滑动窗口维持至多 `concurrency` 个并发（TaskGroup 补位）。
    private func scanOnce(hosts: [ConnKit.Host], concurrency: Int) async {
        guard !hosts.isEmpty else { return }
        var iterator = hosts.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while running < max(1, concurrency), let host = iterator.next() {
                group.addTask { await self.collectOne(host) }
                running += 1
            }
            while await group.next() != nil {
                if let host = iterator.next() {
                    group.addTask { await self.collectOne(host) }
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
        _ host: ConnKit.Host, includeExtended: Bool = false, includeProcesses: Bool = false
    ) async {
        // 只有「本来有读数」的主机才享受这次宽限。首采失败直接如实报错；
        // 已判定故障的主机（metrics 已被清空）也不再重试，避免每轮双倍连接尝试。
        let allowsRetry = metrics[host.id] != nil

        if let error = await attempt(
            host, includeExtended: includeExtended, includeProcesses: includeProcesses
        ) {
            if allowsRetry {
                if let retryError = await attempt(
                    host, includeExtended: includeExtended, includeProcesses: includeProcesses
                ) {
                    record(retryError, for: host)
                }
            } else {
                record(error, for: host)
            }
        }
        phases[host.id] = .idle
    }

    /// 一次采集尝试。
    ///
    /// 成功返回 nil；失败驱逐会话并返回错误，**不写 `errors`**——
    /// 是否呈现为故障由 `collectOne` 决定。
    private func attempt(
        _ host: ConnKit.Host, includeExtended: Bool, includeProcesses: Bool
    ) async -> Error? {
        // 池里没有会话 = 本次要握手。首采（无读数）仍走骨架态，不算重连。
        let needsHandshake = await !connectionManager.hasPooledSession(for: host)
        phases[host.id] = (needsHandshake && metrics[host.id] != nil) ? .reconnecting : .collecting
        do {
            let session = try await connectionManager.session(for: host)
            let result = try await collector.collect(
                host: host, session: session,
                includeExtended: includeExtended, includeProcesses: includeProcesses
            )
            // 本轮没采的段（切走的概览/进程段）沿用上次值，切回来不闪空/不重载。
            metrics[host.id] = result.carryingOver(
                metrics[host.id], keepExtended: !includeExtended, keepProcesses: !includeProcesses
            )
            errors[host.id] = nil
            return nil
        } catch {
            // #2：驱逐可能已死的会话，下次尝试重新握手 → 断网后自愈。
            await connectionManager.invalidate(host: host)
            return error
        }
    }

    /// 认定为故障：写错误文案并清掉过期读数。
    private func record(_ error: Error, for host: ConnKit.Host) {
        errors[host.id] = error.friendlyDiagnosis
        // #1：清掉过期实时指标，主机立即显示离线/未知，而不是一直挂着旧的绿色读数。
        metrics[host.id] = nil
    }
}
