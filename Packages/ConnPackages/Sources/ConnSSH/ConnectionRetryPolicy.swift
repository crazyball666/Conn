import Foundation

/// 私有网络/隧道刚建立时的数据面可能比本地 `Running` 状态晚几秒就绪。
/// 只对明确可重试的网络错误做有界退避重试，认证、主机指纹和配置错误不重试。
public enum ConnectionRetryPolicy {
    public static let maximumAttempts = 3

    public static func isTransient(_ error: Error) -> Bool {
        guard let ssh = error as? SSHError else { return false }
        switch ssh {
        case .connectionRefused, .timeout, .channelClosed:
            return true
        default:
            return false
        }
    }

    /// attempt 为刚刚失败的那一次（1-based）。
    public static func delay(afterFailedAttempt attempt: Int) -> Duration {
        switch attempt {
        case 1: .milliseconds(300)
        case 2: .milliseconds(800)
        default: .zero
        }
    }
}
