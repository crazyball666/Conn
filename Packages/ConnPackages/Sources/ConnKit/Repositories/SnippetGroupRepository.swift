import Foundation

/// 命令分组仓库协议。签名与 `HostGroupRepository` 保持一致。
public protocol SnippetGroupRepository: Sendable {
    /// 全部分组，按排序权重再按名称。
    func allGroups() throws -> [SnippetGroup]
    /// 新建或重命名（同 id 覆盖）。
    func save(_ group: SnippetGroup) throws
    /// 删除（真 DELETE）。成员行由外键级联清理。
    func delete(id: String) throws
}
