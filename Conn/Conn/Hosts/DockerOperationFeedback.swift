import ConnOps
import Foundation

enum DockerOperationFeedback {
    static func message(
        for outcome: DockerOperationOutcome,
        label: String,
        auditSaved: Bool = true
    ) -> String {
        let resultText = message(for: outcome, label: label)
        return auditSaved ? resultText : resultText + L("；审计未保存")
    }

    private static func message(for outcome: DockerOperationOutcome, label: String) -> String {
        switch outcome {
        case .success:
            String(format: L("%@ 成功"), label)
        case let .knownFailure(exitCode, remoteMessage):
            if let remoteMessage {
                String(format: L("%@ 失败：%@"), label, remoteMessage)
            } else {
                String(format: L("%@ 失败（退出码 %d）"), label, exitCode)
            }
        case let .unknown(remoteMessage):
            unknownMessage(label: label, remoteMessage: remoteMessage)
        case let .rejected(message):
            message
        }
    }

    private static func unknownMessage(label: String, remoteMessage: String?) -> String {
        let prefix = String(format: L("%@ 结果未知"), label)
        guard let remoteMessage, !remoteMessage.isEmpty else { return prefix }
        return "\(prefix)：\(remoteMessage)"
    }
}
