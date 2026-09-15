import Foundation

/// Per-host outbound proxy settings. Credentials are resolved from Keychain by
/// the host id and are intentionally not part of this value.
public struct SSHProxyConfiguration: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case httpConnect
        case socks5
    }

    public enum Authentication: String, Codable, Sendable, CaseIterable {
        case none
        case password
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case emptyHost
        case invalidPort
        case missingUsername
    }

    public var kind: Kind
    public var host: String
    public var port: Int
    public var authentication: Authentication
    public var username: String

    public init(
        kind: Kind = .httpConnect,
        host: String = "",
        port: Int? = nil,
        authentication: Authentication = .none,
        username: String = ""
    ) {
        self.kind = kind
        self.host = host
        self.port = port ?? (kind == .httpConnect ? 8080 : 1080)
        self.authentication = authentication
        self.username = username
    }

    public var validationError: ValidationError? {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyHost }
        if !(1 ... 65535).contains(port) { return .invalidPort }
        if authentication == .password,
           username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingUsername
        }
        return nil
    }
}
