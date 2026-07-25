import Foundation

/// TCP 连接统计（`/proc/net/snmp` 的 Tcp 行）。
///
/// 运维语义：重传率高 → 链路质量差/拥塞；建连失败(AttemptFails)多 → 端口不通/被拒
/// /半开攻击；主动/被动建连数反映连接是「我方发起」还是「对端接入」。
public struct TCPStats: Sendable, Equatable {
    /// 重传率 %（RetransSegs / OutSegs）。
    public let retransRate: Double
    /// 主动建连累计（ActiveOpens）。
    public let activeOpens: Int64
    /// 被动建连累计（PassiveOpens）。
    public let passiveOpens: Int64
    /// 建连失败累计（AttemptFails）。
    public let attemptFails: Int64

    public init(retransRate: Double, activeOpens: Int64, passiveOpens: Int64, attemptFails: Int64) {
        self.retransRate = retransRate
        self.activeOpens = activeOpens
        self.passiveOpens = passiveOpens
        self.attemptFails = attemptFails
    }
}

/// 单块网卡的读数（累计 + 速率 + IP）。
public struct NetInterface: Sendable, Equatable, Identifiable {
    public let name: String
    public let ip: String?
    /// 收/发速率（字节/秒），首采无基线时 nil。
    public let rxRate: Double?
    public let txRate: Double?
    /// 收/发累计字节。
    public let rxTotal: Int64
    public let txTotal: Int64
    public var id: String { name }

    public init(name: String, ip: String?, rxRate: Double?, txRate: Double?, rxTotal: Int64, txTotal: Int64) {
        self.name = name
        self.ip = ip
        self.rxRate = rxRate
        self.txRate = txRate
        self.rxTotal = rxTotal
        self.txTotal = txTotal
    }
}

/// `/proc/net/dev` 单行原始累计（供 `MetricCollector` 差分算速率）。
public struct RawInterface: Sendable, Equatable {
    public let name: String
    public let rx: Int64
    public let tx: Int64

    public init(name: String, rx: Int64, tx: Int64) {
        self.name = name
        self.rx = rx
        self.tx = tx
    }
}
