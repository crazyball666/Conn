import Foundation

/// 指标时序仓库协议。
///
/// 由 `ConnStore.MetricStore` 提供 GRDB 实现。原始样本保留 48h（启动时清理），
/// 供离线时查看最后一次快照（PRD §6）。历史曲线是专业版功能，v1.0 只留最近样本。
public protocol MetricRepository: Sendable {
    /// 写入一条样本（`(host_uuid, ts)` 冲突则覆盖）。
    func record(_ sample: MetricSample) throws
    /// 某主机最近一条样本，无则 nil。
    func latest(hostUUID: String) throws -> MetricSample?
    /// 某主机 `since`（含）之后的样本，按时间升序。
    func recentSamples(hostUUID: String, since: Int64) throws -> [MetricSample]
    /// 清理早于 `ts` 的样本（48h TTL）。
    func pruneSamples(olderThan ts: Int64) throws
}
