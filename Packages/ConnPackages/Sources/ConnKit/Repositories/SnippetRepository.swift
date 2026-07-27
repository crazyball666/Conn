import Foundation

/// 片段仓库协议。由 `ConnStore.SnippetStore` 提供 GRDB 实现。
public protocol SnippetRepository: Sendable {
    /// 全部未删除的片段，按排序权重与标题。
    func allSnippets() throws -> [Snippet]
    func snippet(id: String) throws -> Snippet?
    /// 插入或整体覆盖。
    func save(_ snippet: Snippet) throws
    /// 删除（真 DELETE，不可恢复）。
    func delete(id: String) throws
    /// 片段数量（免费额度用）。
    func count() throws -> Int
    /// 可供片段选择的全部分组，包含显式创建的分组和已有片段正在使用的分组。
    func allFolders() throws -> [String]
    /// 创建一个可供片段选择的分组；同名分组幂等。
    func saveFolder(_ name: String) throws
    /// 删除分组，仅解除命令归属，不删除命令本身。
    func deleteFolder(_ name: String) throws
}
