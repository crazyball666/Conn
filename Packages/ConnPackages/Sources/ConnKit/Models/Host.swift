import Foundation

/// 一台被管理的服务器。
///
/// 对应 GRDB `host` 表。**凭据本身绝不存在本类型中**——`credentialRef` 只是
/// Keychain 条目的引用键（形如 `conn.host.<uuid>.password`），密文永不入库。
public struct Host: Identifiable, Codable, Sendable, Equatable, Hashable {
    /// 认证方式。
    public enum AuthKind: String, Codable, Sendable, CaseIterable {
        case password
        case key
        case keyPassphrase = "key_passphrase"
        case agent
    }

    /// 主机健康状态。驱动仪表盘 HealthCard 的红黄绿三态。
    public enum HealthStatus: String, Codable, Sendable {
        /// 各项指标均在阈值内。
        case ok
        /// 有指标越过警戒线（>80%）。
        case warn
        /// 有指标越过危险线（>92%），或关键服务异常。
        case crit
        /// 最近一次采集失败（网络/认证问题）。
        case offline
        /// 从未采集过。
        case unknown
    }

    public let id: String
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var authKind: AuthKind

    /// Keychain 条目引用键，非密文本身。
    public var credentialRef: String?
    /// 关联的 `SSHKey.id`。
    public var keyUUID: String?
    /// 跳板链，按连接顺序排列的 `Host.id`（A→B→C）。
    public var jumpChain: [String]
    public var groupUUID: String?
    public var tags: [String]
    public var icon: String?
    public var color: String?
    public var note: String?
    /// VPS 到期提醒时间（毫秒）。PRD §5.1 的 P2 功能，v1.0 只存不用。
    public var expireAt: Int64?
    public var sortOrder: Int

    public var status: HealthStatus
    public let createdAt: Int64
    public var updatedAt: Int64
    /// 同步引擎用的脏标记。v1.0 只写不读，v1.1 ConnSync 消费。
    public var syncDirty: Bool
    /// 墓碑时间戳。非 nil 表示已删除，30 天后物理清除。
    public var deletedAt: Int64?

    public init(
        id: String = UUID().uuidString,
        name: String,
        address: String,
        username: String,
        port: Int = 22,
        authKind: AuthKind = .key,
        credentialRef: String? = nil,
        keyUUID: String? = nil,
        jumpChain: [String] = [],
        groupUUID: String? = nil,
        tags: [String] = [],
        icon: String? = nil,
        color: String? = nil,
        note: String? = nil,
        expireAt: Int64? = nil,
        sortOrder: Int = 0,
        status: HealthStatus = .unknown,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
        self.port = port
        self.authKind = authKind
        self.credentialRef = credentialRef
        self.keyUUID = keyUUID
        self.jumpChain = jumpChain
        self.groupUUID = groupUUID
        self.tags = tags
        self.icon = icon
        self.color = color
        self.note = note
        self.expireAt = expireAt
        self.sortOrder = sortOrder
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
        self.deletedAt = deletedAt
    }

    /// `user@address` 或 `user@address:port`（标准 22 端口省略）。
    ///
    /// 用于 HealthCard 副标题与主机列表；设计规范要求此处走 mono 字体。
    public var displayAddress: String {
        port == 22 ? "\(username)@\(address)" : "\(username)@\(address):\(port)"
    }

    /// 是否为生产环境主机。
    ///
    /// 带 `prod` 标签时，终端高危命令需二次确认（技术实现方案 §4.2）。
    public var isProduction: Bool {
        tags.contains { $0.lowercased() == "prod" }
    }

    /// 是否经由跳板机连接。
    public var usesJumpHost: Bool { !jumpChain.isEmpty }
}
