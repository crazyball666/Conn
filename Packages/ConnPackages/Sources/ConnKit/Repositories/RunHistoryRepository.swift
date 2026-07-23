import Foundation

/// 执行审计仓库协议。由 `ConnStore.RunHistoryStore` 提供 GRDB 实现。
public protocol RunHistoryRepository: Sendable {
    /// 追加一条记录。
    func record(_ entry: RunHistoryEntry) throws
    /// 最近记录，按时间降序。`hostUUID` 为 nil 时取全部主机。
    func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry]
}
