import ConnKit
import ConnSSH
import Foundation
import Observation

/// 进程页独立调度器。只采集进程列表，生命周期与主机基础指标监控互不影响。
@MainActor
@Observable
public final class ProcessMonitor {
    public private(set) var processes: [RemoteProcess] = []
    public private(set) var errorText: String?
    public private(set) var capabilityState: CapabilityState?
    public private(set) var isLoading = false
    public private(set) var isRefreshing = false

    private let connectionManager: ConnectionManager
    private let collector: ProcessCollector
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isCollecting = false
    private var pendingCollection: PendingCollection?

    private struct PendingCollection {
        let host: ConnKit.Host
        let generation: Int
    }

    public init(
        connectionManager: ConnectionManager,
        collector: ProcessCollector = ProcessCollector()
    ) {
        self.connectionManager = connectionManager
        self.collector = collector
    }

    /// 显示进程页时立即采一轮，随后按间隔刷新。
    public func start(host: ConnKit.Host, interval: Duration = .seconds(3)) {
        stop()
        let scanGeneration = generation
        isLoading = processes.isEmpty
        task = Task { [weak self] in
            guard let self else { return }
            while self.isCurrent(scanGeneration) && !Task.isCancelled {
                await self.collect(host: host, generation: scanGeneration)
                guard self.isCurrent(scanGeneration), !Task.isCancelled else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 页面隐藏后停止后续进程采集；已缓存的列表保留，返回页面时可立即展示。
    public func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        pendingCollection = nil
        isLoading = false
        isRefreshing = false
    }

    /// 用户重试时立刻补采，不等待下一轮。
    public func refresh(host: ConnKit.Host) async {
        await collect(host: host, generation: generation)
    }

    private func collect(host: ConnKit.Host, generation scanGeneration: Int) async {
        guard isCurrent(scanGeneration) else { return }
        guard !isCollecting else {
            pendingCollection = PendingCollection(host: host, generation: scanGeneration)
            return
        }
        isCollecting = true
        isLoading = processes.isEmpty
        isRefreshing = !processes.isEmpty

        do {
            let context = try await connectionManager.platformContext(for: host)
            let result = try await collector.collect(
                session: context.session,
                profile: context.profile
            )
            if isCurrent(scanGeneration) {
                processes = result.processes
                capabilityState = result.capabilityState
                errorText = nil
            }
        } catch let error as ProcessCollectionError {
            if isCurrent(scanGeneration) {
                capabilityState = error.capabilityState
                errorText = error.localizedDescription
            }
        } catch {
            if isCurrent(scanGeneration) {
                await connectionManager.invalidate(host: host)
                if isCurrent(scanGeneration) {
                    errorText = error.friendlyDiagnosis
                }
            }
        }

        isCollecting = false
        if isCurrent(scanGeneration) {
            isLoading = false
            isRefreshing = false
        }
        if let pendingCollection {
            self.pendingCollection = nil
            if isCurrent(pendingCollection.generation) {
                await collect(host: pendingCollection.host, generation: pendingCollection.generation)
            }
        }
    }

    private func isCurrent(_ scanGeneration: Int) -> Bool {
        generation == scanGeneration
    }
}
