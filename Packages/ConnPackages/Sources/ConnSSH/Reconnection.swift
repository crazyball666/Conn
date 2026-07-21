import Foundation

/// 断线重连的退避策略。
///
/// 技术方案 §4.1：网络切换或通道 EOF → 指数退避 1s/2s/4s 共 3 次。
/// 纯值类型，无副作用，host 可测。
public struct ReconnectPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let baseDelay: Duration

    public init(maxAttempts: Int = 3, baseDelay: Duration = .seconds(1)) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
    }

    /// 每次重连前的等待时长序列：base × 2⁰, 2¹, 2²…
    public func delays() -> [Duration] {
        (0 ..< maxAttempts).map { attempt in
            baseDelay * Int(pow(2.0, Double(attempt)))
        }
    }
}
