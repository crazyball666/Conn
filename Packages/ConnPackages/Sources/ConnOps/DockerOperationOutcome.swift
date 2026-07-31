import ConnSSH
import Foundation

/// Docker 写命令已经拿到远端退出结果时的可展示终态。
///
/// stdout 可能包含镜像输出、环境变量或业务数据，失败摘要只采用 stderr；
/// 审计仍只保存退出码，不保存这里的远端文本。
public enum DockerOperationOutcome: Equatable, Sendable {
    case success
    case knownFailure(exitCode: Int32, remoteMessage: String?)
    case unknown(remoteMessage: String?)
    case rejected(message: String)

    public init(result: ExecResult) {
        guard result.exitCode != 0 else {
            self = .success
            return
        }
        let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        self = .knownFailure(
            exitCode: result.exitCode,
            remoteMessage: message.isEmpty ? nil : message
        )
    }

    public var isSuccess: Bool {
        self == .success
    }
}
