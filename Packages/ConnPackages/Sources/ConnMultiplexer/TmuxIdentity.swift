import Foundation

public enum TmuxIdentityError: Error, Sendable, Equatable {
    case invalidNamedSocket(String)
    case invalidSocketPath(String)
    case invalidServerPID(Int32)
    case invalidServerStartTime(Int64)
}

/// A validated tmux server locator. The value is normalized before it can become part of a
/// profile key, preventing textually different paths from selecting the same obvious socket.
public struct TmuxServerLocator: Sendable, Codable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case `default`
        case namedSocket
        case socketPath
    }

    public static let `default` = Self(kind: .default, value: nil)

    public let kind: Kind
    public let value: String?

    public static func namedSocket(_ value: String) throws -> Self {
        guard !value.isEmpty,
              !value.contains("/"),
              !containsControlCharacter(value)
        else {
            throw TmuxIdentityError.invalidNamedSocket(value)
        }
        return Self(kind: .namedSocket, value: value)
    }

    public static func socketPath(_ value: String) throws -> Self {
        Self(kind: .socketPath, value: try normalizedSocketPath(value))
    }

    public var arguments: [String] {
        switch kind {
        case .default:
            []
        case .namedSocket:
            ["-L", value!]
        case .socketPath:
            ["-S", value!]
        }
    }

    public var configurationKey: String {
        switch kind {
        case .default:
            "default"
        case .namedSocket:
            "named:\(value!)"
        case .socketPath:
            "path:\(value!)"
        }
    }

    private init(kind: Kind, value: String?) {
        self.kind = kind
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .default:
            guard try container.decodeIfPresent(String.self, forKey: .value) == nil else {
                throw TmuxIdentityError.invalidSocketPath("default locator cannot carry a value")
            }
            self = .default
        case .namedSocket:
            self = try .namedSocket(container.decode(String.self, forKey: .value))
        case .socketPath:
            self = try .socketPath(container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(value, forKey: .value)
    }

    fileprivate static func normalizedSocketPath(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !containsControlCharacter(value) else {
            throw TmuxIdentityError.invalidSocketPath(value)
        }

        var normalizedComponents: [Substring] = []
        for component in value.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                throw TmuxIdentityError.invalidSocketPath(value)
            default:
                normalizedComponents.append(component)
            }
        }
        return "/" + normalizedComponents.joined(separator: "/")
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
        }
    }
}

public struct TmuxSessionID: RawRepresentable, Sendable, Codable, Equatable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue, prefix: "$".utf8.first!) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid tmux session ID"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String, prefix: UInt8) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count > 1
            && bytes[0] == prefix
            && bytes.dropFirst().allSatisfy { (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }
    }
}

public struct TmuxWindowID: RawRepresentable, Sendable, Codable, Equatable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue, prefix: "@".utf8.first!) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid tmux window ID"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String, prefix: UInt8) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count > 1
            && bytes[0] == prefix
            && bytes.dropFirst().allSatisfy { (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }
    }
}

public struct TmuxPaneID: RawRepresentable, Sendable, Codable, Equatable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue, prefix: "%".utf8.first!) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid tmux pane ID"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String, prefix: UInt8) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count > 1
            && bytes[0] == prefix
            && bytes.dropFirst().allSatisfy { (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }
    }
}

/// Identity for one running tmux server. PID alone is insufficient because the OS can reuse it.
public struct TmuxServerInstanceToken: Sendable, Codable, Equatable, Hashable {
    public let resolvedSocketPath: String
    public let serverPID: Int32
    public let serverStartTime: Int64

    public init(
        resolvedSocketPath: String,
        serverPID: Int32,
        serverStartTime: Int64
    ) throws {
        guard serverPID > 0 else { throw TmuxIdentityError.invalidServerPID(serverPID) }
        guard serverStartTime > 0 else {
            throw TmuxIdentityError.invalidServerStartTime(serverStartTime)
        }
        self.resolvedSocketPath = try TmuxServerLocator.normalizedSocketPath(resolvedSocketPath)
        self.serverPID = serverPID
        self.serverStartTime = serverStartTime
    }

    private enum CodingKeys: String, CodingKey {
        case resolvedSocketPath
        case serverPID
        case serverStartTime
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            resolvedSocketPath: container.decode(String.self, forKey: .resolvedSocketPath),
            serverPID: container.decode(Int32.self, forKey: .serverPID),
            serverStartTime: container.decode(Int64.self, forKey: .serverStartTime)
        )
    }
}
