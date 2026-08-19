import ConnMultiplexer
import ConnSSH
import ConnUI
import Foundation
import OSLog

private let persistentTerminalDiagnosticsLogger = Logger(
    subsystem: "com.crazyball.Conn",
    category: "PersistentTerminal"
)

/// Product-facing diagnostics for provider-neutral persistent terminal failures.
/// Protocol details stay in ConnMultiplexer; presentation layers get stable,
/// actionable text instead of Foundation's enum-type fallback description.
public extension PersistentTerminalError {
    var userFacingDiagnosis: String {
        switch self {
        case .unsupportedPlatform:
            L("当前主机平台不支持持久终端")
        case let .providerNotRegistered(providerID):
            String(format: L("持久终端 Provider 未注册：%@"), providerID)
        case .executableMissing:
            L("远程主机未安装所需的持久终端程序")
        case let .unsupportedConfigurationVersion(providerID, version):
            String(format: L("%@ 配置版本不受支持：%d"), providerID, version)
        case let .incompatibleVersion(version):
            version.map { String(format: L("远程持久终端版本不兼容：%@"), $0) }
                ?? L("远程持久终端版本不兼容")
        case .serverUnavailable:
            L("远程持久终端服务暂不可用")
        case .socketPermissionDenied:
            L("权限不足，无法访问远程持久终端 Socket")
        case .invalidConfiguration:
            L("持久终端配置无效")
        case let .unsupportedDescriptorVersion(providerID, component, version):
            String(
                format: L("%@ 不支持 %@ 描述版本 %d"),
                providerID,
                component.rawValue,
                version
            )
        case let .unsupportedFeature(providerID, feature):
            String(format: L("%@ 不支持功能：%@"), providerID, feature)
        case .controlModeUnavailable:
            L("远程 Control Mode 当前不可用")
        case .protocolViolation:
            L("远程持久终端返回无法识别的协议数据")
        case .serverInstanceChanged:
            L("远程持久终端服务已重启，请刷新后重试")
        case .bootstrapPreconditionChanged:
            L("远程 Session 状态已变化，请刷新后重试")
        case .staleConfirmation:
            L("操作确认已过期，请重新确认")
        case .staleTarget:
            L("操作目标已变化，请刷新后重试")
        case .remoteObjectMissing:
            L("远程 Session 不存在，请刷新列表")
        case let .commandRejected(message):
            message.isEmpty
                ? L("远程持久终端拒绝执行该操作")
                : String(format: L("远程持久终端拒绝执行该操作：%@"), message)
        case .operationOutcomeUnknown:
            L("操作结果未知，请刷新 Session 状态后确认")
        case .transportClosed:
            L("持久终端连接已断开，请重试")
        }
    }
}

public extension TmuxProviderError {
    var userFacingDiagnosis: String {
        switch self {
        case .malformedProbeOutput:
            L("无法解析远程 tmux 检测结果")
        case let .unsupportedAttachmentMode(mode):
            String(format: L("不支持 tmux 终端连接模式：%@"), mode.rawValue)
        case .attachmentHandshakeFailed:
            L("tmux 终端握手失败，请重试")
        }
    }
}

package func terminalUserFacingDiagnosis(_ error: any Error) -> String {
    if let startupFailure = error as? TerminalStartupFailure {
        persistentTerminalDiagnosticsLogger.error(
            "Startup failed at \(startupFailure.stageID.rawValue, privacy: .public); underlying type: \(String(reflecting: type(of: startupFailure.underlyingError)), privacy: .public)"
        )
        return terminalUserFacingDiagnosis(startupFailure.underlyingError)
    }
    if let persistentError = error as? PersistentTerminalError {
        return persistentError.userFacingDiagnosis
    }
    if let tmuxError = error as? TmuxProviderError {
        return tmuxError.userFacingDiagnosis
    }
    return error.friendlyDiagnosis
}
