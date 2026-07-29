import Foundation

/// 镜像详情（`docker image inspect`）。
public struct ImageDetail: Equatable, Sendable {
    /// 12 位短 ID，与 `ImageInfo.imageID` 同规格便于比对。
    public let id: String
    public let tags: [String]
    public let digest: String?
    public let architecture: String
    public let os: String
    /// 字节数。`docker image inspect` 给的是数值，不是 `docker images` 那种 `142MB` 串。
    public let sizeBytes: Int64
    public let entrypoint: String?
    public let command: String?
    /// 已排序——JSON 数组本身有序但 Labels 是字典，统一排序保证 UI 稳定。
    public let env: [String]
    public let labels: [String]
    /// `2026-01-02 03:04`。缺失为「—」。
    public let created: String

    public init(
        id: String, tags: [String], digest: String?, architecture: String, os: String,
        sizeBytes: Int64, entrypoint: String?, command: String?,
        env: [String], labels: [String], created: String
    ) {
        self.id = id
        self.tags = tags
        self.digest = digest
        self.architecture = architecture
        self.os = os
        self.sizeBytes = sizeBytes
        self.entrypoint = entrypoint
        self.command = command
        self.env = env
        self.labels = labels
        self.created = created
    }
}

/// 镜像的一层（`docker history`）。
///
/// 层的 `ID` 常常是 `<missing>`（非本地构建的层拿不到 ID），所以**不能拿它做
/// Identifiable 的键**，用下标。
public struct ImageLayer: Equatable, Sendable {
    public let id: String
    /// 构建该层的指令。`docker history` 已做过截断处理的原样输出。
    public let createdBy: String
    /// `58.2MB` 这类人类可读串，直接来自 docker。
    public let size: String
    public let createdSince: String

    public init(id: String, createdBy: String, size: String, createdSince: String) {
        self.id = id
        self.createdBy = createdBy
        self.size = size
        self.createdSince = createdSince
    }
}
