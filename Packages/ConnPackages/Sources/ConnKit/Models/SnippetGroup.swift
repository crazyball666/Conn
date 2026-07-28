import Foundation

/// 命令分组。
///
/// 与 `HostGroup` 同构：uuid 主键，因此重命名只改一行 `name`，
/// 成员关系纹丝不动；同名分组也不会互相撞车。
public struct SnippetGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var sortOrder: Int
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        sortOrder: Int = 0,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
    }
}
