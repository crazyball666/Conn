import ConnMultiplexer
import ConnSSH
import ConnUI
import Foundation

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
        case .providerDisabled:
            L("当前持久终端配置已停用")
        case let .profileUnavailable(profileID):
            String(format: L("持久终端配置不可用：%@"), profileID)
        case .executableMissing:
            L("远端未安装所需的持久终端程序")
        case let .incompatibleVersion(version):
            version.map { String(format: L("远端持久终端版本不兼容：%@"), $0) }
                ?? L("远端持久终端版本不兼容")
        case .serverUnavailable:
            L("远端持久终端服务当前不可用")
        case .socketPermissionDenied:
            L("没有权限访问远端持久终端 Socket")
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
            L("远端 Control Mode 当前不可用")
        case .protocolViolation:
            L("远端持久终端返回了无法识别的协议数据")
        case .serverInstanceChanged:
            L("远端持久终端服务已重启，请刷新后重试")
        case .bootstrapPreconditionChanged:
            L("远端 Session 状态已变化，请刷新后重试")
        case .staleConfirmation:
            L("操作确认已过期，请重新确认")
        case .staleTarget:
            L("操作目标已变化，请刷新后重试")
        case .remoteObjectMissing:
            L("远端 Session 已不存在，请刷新列表")
        case let .commandRejected(message):
            message.isEmpty
                ? L("远端持久终端拒绝了操作")
                : String(format: L("远端持久终端拒绝了操作：%@"), message)
        case .operationOutcomeUnknown:
            L("操作结果未知，请刷新远端 Session 后确认")
        case .transportClosed:
            L("持久终端连接已关闭，请重试")
        }
    }
}

public extension TmuxProviderError {
    var userFacingDiagnosis: String {
        switch self {
        case .malformedProbeOutput:
            L("无法解析远端 tmux 探测结果")
        case let .unsupportedAttachmentMode(mode):
            String(format: L("不支持 tmux 终端连接模式：%@"), mode.rawValue)
        case .attachmentHandshakeFailed:
            L("tmux 终端握手失败，请重试")
        }
    }
}

package func terminalUserFacingDiagnosis(_ error: any Error) -> String {
    if let persistentError = error as? PersistentTerminalError {
        return persistentError.userFacingDiagnosis
    }
    if let tmuxError = error as? TmuxProviderError {
        return tmuxError.userFacingDiagnosis
    }
    return error.friendlyDiagnosis
}
