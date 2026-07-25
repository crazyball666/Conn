import Foundation

/// `docker inspect <id>` 的运维视角摘要。纯值类型，解析见 `DockerParser.parseInspect`。
public struct ContainerDetail: Sendable, Equatable {
    public let id: String
    public let name: String
    public let image: String
    public let command: String
    public let created: String
    /// State.Status，如 `running` / `exited`。
    public let statusText: String
    public let startedAt: String
    public let restartCount: Int
    public let restartPolicy: String
    /// 健康检查状态（无健康检查时 nil）。
    public let health: String?
    /// 端口映射，如 `0.0.0.0:80->80/tcp`。
    public let ports: [String]
    /// 挂载，如 `/host/path → /container/path (rw)`。
    public let mounts: [String]
    /// 网络，如 `bridge · 172.17.0.2`。
    public let networks: [String]
    /// 环境变量 `KEY=VALUE`（敏感值可能在此，仅本机展示、不外传）。
    public let env: [String]

    public init(
        id: String, name: String, image: String, command: String, created: String,
        statusText: String, startedAt: String, restartCount: Int, restartPolicy: String,
        health: String?, ports: [String], mounts: [String], networks: [String], env: [String]
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.command = command
        self.created = created
        self.statusText = statusText
        self.startedAt = startedAt
        self.restartCount = restartCount
        self.restartPolicy = restartPolicy
        self.health = health
        self.ports = ports
        self.mounts = mounts
        self.networks = networks
        self.env = env
    }
}
