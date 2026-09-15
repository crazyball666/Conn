import Foundation

/// 可嵌入式私有网络的控制面配置。
///
/// Conn 只保存非敏感配置和 Keychain 引用。auth key 本身由 ConnCrypto 保存，
/// 连接主机时按 profile id 读取，不会因为主机配置导出而泄露。
public struct PrivateNetworkProfile: Identifiable, Codable, Sendable, Equatable, Hashable {
    public enum Provider: String, Codable, Sendable, CaseIterable {
        case tailscale
        case headscale
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case emptyName
        case insecureControlURL
        case invalidControlURL
    }

    public let id: String
    public var name: String
    public var provider: Provider
    public var controlURL: String
    /// Keychain 中 auth key 的引用，不是 auth key 明文。
    public var authKeyRef: String
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        provider: Provider,
        controlURL: String? = nil,
        authKeyRef: String? = nil,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.controlURL = controlURL ?? (provider == .tailscale
            ? "https://controlplane.tailscale.com"
            : "")
        self.authKeyRef = authKeyRef ?? "conn.private-network.\(id).auth-key"
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
    }

    public var validationError: ValidationError? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        guard !controlURL.isEmpty, let url = URL(string: controlURL), url.host != nil else {
            return .invalidControlURL
        }
        guard url.scheme?.lowercased() == "https" else { return .insecureControlURL }
        return nil
    }

    public var isValid: Bool { validationError == nil }
}
