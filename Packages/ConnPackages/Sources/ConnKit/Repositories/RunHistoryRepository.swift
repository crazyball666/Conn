import Foundation

/// 执行审计仓库协议。由 `ConnStore.RunHistoryStore` 提供 GRDB 实现。
public protocol RunHistoryRepository: Sendable {
    /// 追加一条记录。
    func record(_ entry: RunHistoryEntry) throws
    /// 按既有 UUID 更新记录。流式写操作先写 pending，得到最终结果后原地更新。
    func update(_ entry: RunHistoryEntry) throws
    /// 应用重启时把遗留的 pending 统一转为 unknown；远端是否已完成无法安全推断。
    func recoverPending() throws
    /// 最近记录，按时间降序。`hostUUID` 为 nil 时取全部主机。
    func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry]
}
