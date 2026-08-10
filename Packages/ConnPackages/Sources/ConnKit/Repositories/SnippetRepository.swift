import Foundation

/// 片段仓库协议。由 `ConnStore.SnippetStore` 提供 GRDB 实现。
public protocol SnippetRepository: Sendable {
    /// 全部未删除的片段，按排序权重与标题。
    func allSnippets() throws -> [Snippet]
    func snippet(id: String) throws -> Snippet?
    /// 按内置目录稳定键查询；用户/遗留片段没有该键。
    func snippet(builtinKey: String) throws -> Snippet?
    /// 插入或整体覆盖。
    func save(_ snippet: Snippet) throws
    /// 删除（真 DELETE，不可恢复）。
    func delete(id: String) throws
    /// 用户删除的内置键不会在后续目录升级时自动恢复。
    func isBuiltinSuppressed(_ builtinKey: String) throws -> Bool
    func suppressBuiltin(_ builtinKey: String) throws
    /// 已成功处理的内置目录版本，0 表示尚未导入版本化目录。
    func builtinCatalogVersion() throws -> Int
    func setBuiltinCatalogVersion(_ version: Int) throws
    /// 片段数量（免费额度用）。
    func count() throws -> Int
}

/// 让轻量测试仓库和第三方实现保持源码兼容；持久化实现应覆盖 suppression 与版本方法。
public extension SnippetRepository {
    func snippet(builtinKey: String) throws -> Snippet? {
        try allSnippets().first { $0.builtinKey == builtinKey }
    }

    func isBuiltinSuppressed(_ builtinKey: String) throws -> Bool { false }
    func suppressBuiltin(_ builtinKey: String) throws {}
    func builtinCatalogVersion() throws -> Int { 0 }
    func setBuiltinCatalogVersion(_ version: Int) throws {}
}
