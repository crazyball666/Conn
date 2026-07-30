import Foundation

/// 卷列表项（`docker volume ls`）。
///
/// **没有大小字段**：`docker volume ls` 的 `Size` 恒为 `N/A`，卷占用只能靠
/// `docker system df -v`，那条单独异步取（见 `DockerDiskUsage`）。
public struct VolumeInfo: Identifiable, Equatable, Sendable {
    public let name: String
    public let driver: String
    public let scope: String
    public let mountpoint: String

    public var id: String { name }

    public init(name: String, driver: String, scope: String, mountpoint: String) {
        self.name = name
        self.driver = driver
        self.scope = scope
        self.mountpoint = mountpoint
    }
}

/// 卷详情（`docker volume inspect`）。
public struct VolumeDetail: Equatable, Sendable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    /// `2026-01-02 03:04`。缺失为「—」。
    public let createdAt: String
    /// `key=value` 形式，已排序——JSON 字典无序，不排会让 UI 每次刷新跳动。
    public let labels: [String]
    public let options: [String]

    public init(
        name: String, driver: String, mountpoint: String,
        createdAt: String, labels: [String], options: [String]
    ) {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.createdAt = createdAt
        self.labels = labels
        self.options = options
    }
}
