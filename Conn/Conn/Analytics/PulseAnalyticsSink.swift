import ConnAnalytics
import PulseAnalytics

/// ConnAnalytics 的 Pulse SDK 适配层。
///
/// SDK 的 `capture` 返回 true 只表示进入内存队列，不代表已落库；`flush` 是阻塞
/// 调用，必须在后台执行。上传失败时 SDK 保留 WAL 并重试。
@MainActor
final class PulseAnalyticsSink: AnalyticsSink {
    private var isStarted = false

    /// 凭据缺失、格式非法或存储不可用时返回 false，服务整体保持禁用，
    /// 避免把事件写进一个永远不会被接受的 WAL。
    @discardableResult
    func start() -> Bool {
        guard let appID = PulseAnalyticsCredentials.appID,
              let writeKey = PulseAnalyticsCredentials.writeKey,
              let encryptionKey = PulseAnalyticsCredentials.encryptionKeyHex
        else {
            return false
        }
        isStarted = PulseAnalyticsBridge.start(
            withEndpoint: PulseAnalyticsCredentials.endpoint,
            appId: appID,
            writeKey: writeKey,
            encryptionKeyHex: encryptionKey,
            storageDir: nil
        )
        return isStarted
    }

    func capture(_ payload: AnalyticsPayload) {
        guard isStarted else { return }
        _ = PulseAnalyticsBridge.capture(payload.event, properties: payload.properties)
    }

    func flush() {
        guard isStarted else { return }
        Task.detached(priority: .utility) {
            _ = PulseAnalyticsBridge.flush()
        }
    }
}
