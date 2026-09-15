import Foundation

/// Tailscale/Headscale 配置仓库。配置本身不含 auth key 明文。
public protocol PrivateNetworkProfileRepository: Sendable {
    func allProfiles() throws -> [PrivateNetworkProfile]
    func profile(id: String) throws -> PrivateNetworkProfile?
    func save(_ profile: PrivateNetworkProfile) throws
    func delete(id: String) throws
}
