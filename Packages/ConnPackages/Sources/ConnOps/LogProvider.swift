import ConnKit
import Foundation

/// 一个平台的日志源发现能力。日志流命令由发现出的 `LogSource` 自己构造。
public protocol LogProvider: Sendable {
    var platform: RemotePlatformKind { get }
    var discoveryCommand: String { get }
    func parseDiscovery(_ output: String) -> [LogSource]
    func capabilityState(for output: String) -> CapabilityState
}

public struct LinuxLogProvider: LogProvider {
    public let platform = RemotePlatformKind.linux

    public init() {}

    public var discoveryCommand: String { LogPresets.discoveryCommand }

    public func parseDiscovery(_ output: String) -> [LogSource] {
        LogPresets.parseDiscovery(output)
    }

    public func capabilityState(for output: String) -> CapabilityState {
        if output.split(separator: "\n").contains("__JOURNAL__") { return .supported }
        return .degraded(issues: [CapabilityIssue(
            code: .executableMissing,
            detail: "journalctl is unavailable; file logs remain available when discovered",
            fields: ["journal"]
        )])
    }
}

public struct DarwinLogProvider: LogProvider {
    public let platform = RemotePlatformKind.macOS

    public init() {}

    public var discoveryCommand: String {
        [
            "test -x /usr/bin/log && echo __UNIFIED_LOG__",
            "test -f /var/log/system.log && echo \"__FILE__ system-log\"",
            "true",
        ].joined(separator: "; ")
    }

    public func parseDiscovery(_ output: String) -> [LogSource] {
        let lines = Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var sources: [LogSource] = []
        if lines.contains("__UNIFIED_LOG__") {
            sources.append(LogSource(
                id: "darwin-unified",
                title: L("系统日志"),
                subtitle: L("macOS Unified Logging"),
                kind: .unified(predicate: nil)
            ))
        }
        if lines.contains("__FILE__ system-log") {
            sources.append(LogSource(
                id: "system-log",
                title: L("系统日志文件"),
                subtitle: "/var/log/system.log",
                kind: .file(path: "/var/log/system.log")
            ))
        }
        return sources
    }

    public func capabilityState(for output: String) -> CapabilityState {
        if output.split(separator: "\n").contains("__UNIFIED_LOG__") { return .supported }
        return .degraded(issues: [CapabilityIssue(
            code: .executableMissing,
            detail: "/usr/bin/log is unavailable; file logs remain available when discovered",
            fields: ["unifiedLog"]
        )])
    }
}

public enum LogProviderRegistry {
    public static func provider(for platform: RemotePlatformKind) -> (any LogProvider)? {
        switch platform {
        case .linux:
            LinuxLogProvider()
        case .macOS:
            DarwinLogProvider()
        case .windows, .unknown:
            nil
        }
    }
}

public enum LogProviderError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedPlatform(RemotePlatformKind)
    case discoveryFailed(CapabilityIssue)

    public var capabilityState: CapabilityState {
        switch self {
        case let .unsupportedPlatform(platform):
            .unsupported(issue: CapabilityIssue(
                code: .unsupportedPlatform,
                detail: platform.rawValue,
                fields: ["logs"]
            ))
        case let .discoveryFailed(issue):
            .unavailable(issue: issue)
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .unsupportedPlatform(platform):
            "暂不支持发现 \(platform.rawValue) 主机日志"
        case .discoveryFailed:
            "远端日志源探测失败"
        }
    }
}
