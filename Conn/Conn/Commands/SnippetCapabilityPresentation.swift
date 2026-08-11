import ConnKit

/// Pure App-layer projection from capability reports to view-facing localized messages.
struct SnippetCapabilityPresentation {
    let blockerMessage: String?
    let degradedMessage: String?

    init(report: RemoteCapabilityReport) {
        let states = Self.orderedStates(in: report)
        blockerMessage = states.lazy.compactMap { Self.blockerMessage(for: $0.state) }.first
        degradedMessage = states.lazy.compactMap { Self.degradedMessage(for: $0.state) }.first
    }

    private static func orderedStates(
        in report: RemoteCapabilityReport
    ) -> [(capability: RemoteCapability, state: CapabilityState)] {
        report.states.sorted { lhs, rhs in
            if lhs.key == .scriptExecution { return rhs.key != .scriptExecution }
            if rhs.key == .scriptExecution { return false }
            return lhs.key.rawValue < rhs.key.rawValue
        }.map { (capability: $0.key, state: $0.value) }
    }

    private static func blockerMessage(for state: CapabilityState) -> String? {
        switch state {
        case .supported, .degraded:
            nil
        case let .unavailable(issue), let .unsupported(issue):
            blockerMessage(for: issue.code)
        }
    }

    private static func degradedMessage(for state: CapabilityState) -> String? {
        guard case let .degraded(issues) = state else { return nil }
        let reason = issues.map(\.code).min { $0.rawValue < $1.rawValue } ?? .unknown
        return degradedMessage(for: reason)
    }

    private static func blockerMessage(for reason: CapabilityReasonCode) -> String {
        switch reason {
        case .unsupportedPlatform:
            L("当前主机平台不支持执行此片段。")
        case .executableMissing:
            L("远程主机缺少执行此片段所需的命令。")
        case .permissionDenied:
            L("当前用户没有执行此片段所需的权限。")
        case .daemonNotRunning:
            L("执行此片段所需的服务未运行。")
        case .partialData:
            L("远程主机未提供执行此片段所需的完整数据。")
        case .queryFailed:
            L("无法确认远程主机是否满足片段要求。")
        case .unknown:
            L("远程主机暂时无法满足片段要求。")
        }
    }

    private static func degradedMessage(for reason: CapabilityReasonCode) -> String {
        switch reason {
        case .unsupportedPlatform:
            L("当前主机平台仅支持此片段的部分能力，仍可继续执行。")
        case .executableMissing:
            L("远程主机缺少部分可选命令，片段仍可继续执行。")
        case .permissionDenied:
            L("部分片段能力受权限限制，仍可继续执行。")
        case .daemonNotRunning:
            L("部分片段能力依赖的服务未运行，仍可继续执行。")
        case .partialData:
            L("部分远程能力数据不可用，片段仍可继续执行。")
        case .queryFailed:
            L("部分片段要求无法确认，仍可继续执行。")
        case .unknown:
            L("部分片段能力状态未知，仍可继续执行。")
        }
    }
}
