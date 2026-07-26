import Foundation

/// 片段仓库协议。由 `ConnStore.SnippetStore` 提供 GRDB 实现。
public protocol SnippetRepository: Sendable {
    /// 全部未删除的片段，按排序权重与标题。
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
    /// 可供片段选择的全部分组，包含显式创建的分组和已有片段正在使用的分组。
    func allFolders() throws -> [String]
    /// 创建一个可供片段选择的分组；同名分组幂等。
    func saveFolder(_ name: String) throws
    /// 删除分组，仅解除命令归属，不删除命令本身。
    func deleteFolder(_ name: String) throws
}
