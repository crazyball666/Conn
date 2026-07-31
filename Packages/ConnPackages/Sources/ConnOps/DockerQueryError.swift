import Foundation

public enum DockerQueryError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(exitCode: Int32, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            let remoteMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remoteMessage.isEmpty {
                return remoteMessage
            }
            return String(format: L("Docker 命令失败（退出码 %d）"), exitCode)
        case .invalidResponse:
            return L("Docker 返回的详情无法解析，请重试")
        }
    }
}
