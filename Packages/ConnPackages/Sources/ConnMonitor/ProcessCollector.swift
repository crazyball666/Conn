import ConnKit
import ConnSSH
import Foundation

public struct ProcessCollectionResult: Sendable, Equatable {
    public let processes: [RemoteProcess]
    public let capabilityState: CapabilityState

    public init(processes: [RemoteProcess], capabilityState: CapabilityState) {
        self.processes = processes
        self.capabilityState = capabilityState
    }
}

public enum ProcessCollectionError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedPlatform(RemotePlatformKind)
    case commandFailed(CapabilityIssue)

    public var capabilityState: CapabilityState {
        switch self {
        case let .unsupportedPlatform(platform):
            .unsupported(issue: CapabilityIssue(
                code: .unsupportedPlatform,
                detail: platform.rawValue,
                fields: ["processes"]
            ))
        case let .commandFailed(issue):
            .unavailable(issue: issue)
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .unsupportedPlatform(platform):
            "暂不支持采集 \(platform.rawValue) 主机进程"
        case let .commandFailed(issue):
            switch issue.code {
            case .permissionDenied:
                "没有权限读取远端进程列表"
            case .executableMissing:
                "远端缺少可用的进程查询命令"
            default:
                "读取远端进程列表失败"
            }
        }
    }
}

/// 独立的进程采集器：复用 SSH 会话，但不读取或更新主机基础指标。
public struct ProcessCollector: Sendable {
    public init() {}

    public func collect(
        session: any SSHSession,
        profile: RemotePlatformProfile
    ) async throws -> ProcessCollectionResult {
        guard let provider = ProcessProviderRegistry.provider(for: profile.kind) else {
            throw ProcessCollectionError.unsupportedPlatform(profile.kind)
        }
        let result = try await session.exec(provider.command)
        guard result.isSuccess else {
            let message = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            throw ProcessCollectionError.commandFailed(Self.issue(for: message))
        }
        return ProcessCollectionResult(
            processes: provider.parse(result.stdoutText),
            capabilityState: provider.capabilityState
        )
    }

    private static func issue(for message: String) -> CapabilityIssue {
        let normalized = message.lowercased()
        let code: CapabilityReasonCode
        if normalized.contains("permission denied") || normalized.contains("operation not permitted") {
            code = .permissionDenied
        } else if normalized.contains("not found") || normalized.contains("illegal option") {
            code = .executableMissing
        } else {
            code = .queryFailed
        }
        return CapabilityIssue(code: code, detail: message, fields: ["processes"])
    }
}
