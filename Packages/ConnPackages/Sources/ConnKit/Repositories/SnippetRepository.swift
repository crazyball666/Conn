import Foundation

/// 片段仓库协议。由 `ConnStore.SnippetStore` 提供 GRDB 实现。
public protocol SnippetRepository: Sendable {
    /// 全部未删除的片段，置顶优先、再按排序权重与标题。
    func allSnippets() throws -> [Snippet]
    func snippet(id: String) throws -> Snippet?
    /// 插入或整体覆盖。
    func save(_ snippet: Snippet) throws
    /// 软删除（写墓碑）。
    func softDelete(id: String) throws
    /// 未删除片段数量（免费额度用）。
    func count() throws -> Int
    /// 全部行数，**含软删除墓碑**。首启导入判空用它：用户删光后墓碑仍在，
    /// 不会被当成「从未导入」而重新导入内置片段。
    func totalCount() throws -> Int
}
