import ConnKit
import ConnSSH
import Foundation
import Observation

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
    public private(set) var lastScanAt: Date?

    private let connectionManager: ConnectionManager
    private let collector: MetricCollector
    private let store: (any MetricRepository)?
    private let now: () -> Date
    private var task: Task<Void, Never>?

    public init(
        connectionManager: ConnectionManager,
        collector: MetricCollector = MetricCollector(),
        store: (any MetricRepository)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.connectionManager = connectionManager
        self.collector = collector
        self.store = store
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

    /// 单机详情模式：只高频轮询这一台。
    public func startDetail(host: ConnKit.Host, interval: Duration = .seconds(3)) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.collectOne(host)
                self.lastScanAt = self.now()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 停止轮询（页面不可见 / 切走时调用）。
    public func stop() {
        task?.cancel()
        task = nil
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
    private func collectOne(_ host: ConnKit.Host) async {
        do {
            let session = try await connectionManager.session(for: host)
            let result = try await collector.collect(host: host, session: session)
            metrics[host.id] = result
            errors[host.id] = nil
            // #18：首采 CPU 尚无差分(nil)，此时 sample.cpu 是占位 0，不落库以免污染历史。
            if let store, result.cpu != nil {
                let sample = result.sample
                Task.detached(priority: .utility) { try? store.record(sample) }
            }
        } catch {
            errors[host.id] = Self.friendly(error)
            // #1：清掉过期实时指标，主机立即显示离线/未知，而不是一直挂着旧的绿色读数。
            metrics[host.id] = nil
            // #2：驱逐可能已死的会话，下一轮采集重新握手 → 断网后自愈。
            await connectionManager.invalidate(host: host)
        }
    }

    private static func friendly(_ error: Error) -> String {
        if let sshError = error as? SSHError {
            // 只取诊断首行，卡片上不铺整段
            return sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? sshError.diagnosis
        }
        return error.localizedDescription
    }
}
