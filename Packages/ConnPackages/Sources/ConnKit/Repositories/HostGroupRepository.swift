import Foundation

/// 主机分组仓库协议。
public protocol HostGroupRepository: Sendable {
    /// 全部未删除分组，按排序权重再按名称。
    func allGroups() throws -> [HostGroup]
    func save(_ group: HostGroup) throws
    func softDelete(id: String) throws
}
