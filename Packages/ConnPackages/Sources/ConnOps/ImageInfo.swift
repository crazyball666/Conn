import Foundation

/// 一个 Docker 镜像（`docker images` 的合并视图）。
public struct ImageInfo: Identifiable, Sendable, Equatable, Hashable {
    /// 镜像短 ID。
    public let imageID: String
    public let repository: String
    public let tag: String
    /// 人类可读大小串，如 `142MB`。
    public let size: String
    /// 创建时间串，如 `2 weeks ago`。
    public let created: String

    /// 同一镜像 ID 可有多条 tag，用「ID|repo:tag」保证 ForEach 唯一。
    public var id: String { "\(imageID)|\(repository):\(tag)" }

    /// 悬空镜像（无 tag，`<none>`）——`docker image prune` 的清理对象。
    public var isDangling: Bool { repository == "<none>" || tag == "<none>" }

    /// 展示名：悬空显示短 ID，否则 `repo:tag`。
    public var displayName: String { isDangling ? imageID : "\(repository):\(tag)" }

    /// 传给 `docker rmi` 的引用：有 tag 用 `repo:tag`（只删该 tag），否则用 ID。
    public var reference: String { isDangling ? imageID : "\(repository):\(tag)" }

    public init(imageID: String, repository: String, tag: String, size: String, created: String) {
        self.imageID = imageID
        self.repository = repository
        self.tag = tag
        self.size = size
        self.created = created
    }
}
