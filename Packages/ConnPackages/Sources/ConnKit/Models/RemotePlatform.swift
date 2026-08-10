import Foundation

/// SSH 目标主机的操作系统族。`.unknown` 表示探测成功但签名未识别。
public enum RemotePlatformKind: String, Codable, Sendable, Hashable {
    case linux
    case macOS
    case windows
    case unknown
}

/// 上层可按平台提供或降级的远端能力。
public enum RemoteCapability: String, Codable, Sendable, Hashable {
    case hostMetrics
    case processes
    case logs
    case builtinCommands
    case docker
    case sftp
    case terminal
}

/// 稳定、可测试的能力降级原因；面向用户的文案由 App 层本地化。
public enum CapabilityReasonCode: String, Codable, Sendable, Hashable {
    case unsupportedPlatform
    case executableMissing
    case permissionDenied
    case daemonNotRunning
    case partialData
    case queryFailed
    case unknown
}

/// 一项能力不可用或部分可用时的结构化诊断。
public struct CapabilityIssue: Codable, Sendable, Equatable, Hashable {
    public let code: CapabilityReasonCode
    public let detail: String?
    /// 受影响的统一字段名，例如 `cpu`、`tcp`、`threadCount`。
    public let fields: [String]

    public init(
        code: CapabilityReasonCode,
        detail: String? = nil,
        fields: [String] = []
    ) {
        self.code = code
        self.detail = detail
        self.fields = fields
    }
}

/// 某项远端能力在一次探测时的状态。
public enum CapabilityState: Codable, Sendable, Equatable {
    case supported
    case degraded(issues: [CapabilityIssue])
    case unavailable(issue: CapabilityIssue)
    case unsupported(issue: CapabilityIssue)
}

/// 相对稳定的平台事实；不包含 Docker daemon 等会动态变化的能力状态。
public struct RemotePlatformProfile: Codable, Sendable, Equatable {
    public let kind: RemotePlatformKind
    public let release: String?
    public let architecture: String?
    public let shell: ShellInterpreter?

    public init(
        kind: RemotePlatformKind,
        release: String? = nil,
        architecture: String? = nil,
        shell: ShellInterpreter? = nil
    ) {
        self.kind = kind
        self.release = release
        self.architecture = architecture
        self.shell = shell
    }
}

/// 动态能力快照。与平台画像分离，避免长期缓存权限和 daemon 状态。
public struct RemoteCapabilityReport: Codable, Sendable, Equatable {
    public let states: [RemoteCapability: CapabilityState]
    public let observedAt: Date

    public init(
        states: [RemoteCapability: CapabilityState],
        observedAt: Date = Date()
    ) {
        self.states = states
        self.observedAt = observedAt
    }

    public subscript(capability: RemoteCapability) -> CapabilityState? {
        states[capability]
    }
}
