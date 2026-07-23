import ConnKit
import Foundation
import GRDB

/// `metric_sample` 表的 GRDB 记录。主键 `(host_uuid, ts)`。
///
/// 原始样本 48h TTL（启动时 prune）。v1.0 只留最近样本供离线快照与实时读数；
/// 历史曲线是专业版功能，故不做每小时聚合表。
struct MetricRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "metric_sample"

    var hostUUID: String
    var ts: Int64
    var cpu: Double
    var mem: Double
    var load1: Double
    var diskUsed: Double
    var diskTotal: Double
    var netRx: Int64
    var netTx: Int64

    enum CodingKeys: String, CodingKey {
        case ts, cpu, mem, load1
        case hostUUID = "host_uuid"
        case diskUsed = "disk_used"
        case diskTotal = "disk_total"
        case netRx = "net_rx"
        case netTx = "net_tx"
    }
}

extension MetricRecord {
    init(_ sample: MetricSample) {
        hostUUID = sample.hostUUID
        ts = sample.ts
        cpu = sample.cpu
        mem = sample.mem
        load1 = sample.load1
        diskUsed = sample.diskUsed
        diskTotal = sample.diskTotal
        netRx = sample.netRx
        netTx = sample.netTx
    }

    func toDomain() -> MetricSample {
        MetricSample(
            hostUUID: hostUUID,
            ts: ts,
            cpu: cpu,
            mem: mem,
            load1: load1,
            diskUsed: diskUsed,
            diskTotal: diskTotal,
            netRx: netRx,
            netTx: netTx
        )
    }
}
