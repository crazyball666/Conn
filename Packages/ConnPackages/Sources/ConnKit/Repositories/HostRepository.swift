import Foundation

/// 主机仓库协议。
///
/// 由 `ConnStore.HostStore` 提供 GRDB 实现。
/// 技术实现方案 §1.1：所有跨层交互经协议注入，**禁止单例直取**——
/// 这是测试能整体替换数据层的前提。
public protocol HostRepository: Sendable {
    /// 全部未删除的主机，按排序权重再按名称排序。
    func allHosts() throws -> [Host]
    /// 按 id 取一台主机。已软删除的返回 nil。
    func host(id: String) throws -> Host?
    /// 插入或整体覆盖。
    func save(_ host: Host) throws
    /// 软删除（写墓碑）。
    func delete(id: String) throws
}
