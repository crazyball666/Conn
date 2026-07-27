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
}
