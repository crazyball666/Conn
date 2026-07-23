import Foundation

/// 一个 Docker 容器的合并视图（`docker ps` + `docker stats`）。
public struct ContainerInfo: Identifiable, Sendable, Equatable, Hashable {
    /// 容器运行状态。
    public enum State: String, Sendable, Equatable, Hashable {
        case running, exited, paused, created, restarting, removing, dead, unknown
    }

    /// 短 ID（12 位）。
    public let id: String
    public let name: String
    public let image: String
    public let state: State
    /// 原始状态串，如 `Up 3 days` / `Exited (0) 2 hours ago`。
    public let status: String
    /// 端口映射串，如 `0.0.0.0:80->80/tcp`。
    public let ports: String
    /// CPU 占用百分比（来自 stats，仅运行中容器有值）。
    public var cpuPercent: Double?
    public var memPercent: Double?
    /// 内存用量串，如 `5MiB / 2GiB`。
    public var memUsage: String?

    public var isRunning: Bool { state == .running }

    public init(
        id: String,
        name: String,
        image: String,
        state: State,
        status: String,
        ports: String,
        cpuPercent: Double? = nil,
        memPercent: Double? = nil,
        memUsage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.memUsage = memUsage
    }
}

/// 容器写操作（rm 强确认在 UI 层，方案 §4.4）。
public enum ContainerAction: String, Sendable, CaseIterable, Identifiable {
    case start, stop, restart, remove

    public var id: String { rawValue }

    /// docker 子命令。remove 用 `rm -f` 以便停掉运行中的容器。
    public var verb: String {
        self == .remove ? "rm -f" : rawValue
    }

    public var label: String {
        switch self {
        case .start: L("启动")
        case .stop: L("停止")
        case .restart: L("重启")
        case .remove: L("删除")
        }
    }

    /// 是否高危（需强确认）。
    public var isDestructive: Bool {
        self == .remove
    }
}
