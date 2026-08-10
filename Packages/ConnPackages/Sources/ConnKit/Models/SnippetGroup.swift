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
    /// 内置目录分组的稳定标识；用户创建的分组为 nil。
    ///
    /// 分组显示名允许本地化与用户重命名，因此不能承担幂等导入键的职责。
    public var builtinKey: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        sortOrder: Int = 0,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false,
        builtinKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
        self.builtinKey = builtinKey
    }
}
