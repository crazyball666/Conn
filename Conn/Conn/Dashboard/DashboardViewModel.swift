import ConnKit
import ConnUI
import Foundation
import Observation

/// 仪表盘 ViewModel。
///
/// 负责领域模型 → 展示模型的映射。ConnUI 刻意不依赖 ConnKit，
/// 这层映射是两者之间唯一的桥。
@Observable
@MainActor
final class DashboardViewModel {
    private(set) var cards: [HealthCard.Model] = []
    private(set) var lastScanAt: Date?
    private(set) var errorMessage: String?

    private let hostStore: any HostRepository

    init(hostStore: any HostRepository) {
        self.hostStore = hostStore
    }

    var totalCount: Int { cards.count }

    var abnormalCount: Int {
        cards.count { $0.status == .crit || $0.status == .warn || $0.status == .offline }
    }

    var lastScanText: String {
        guard let lastScanAt else { return "尚未巡检" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return "最后巡检 " + formatter.localizedString(for: lastScanAt, relativeTo: Date())
    }

    func load() {
        do {
            let hosts = try hostStore.allHosts()
            cards = hosts.map(Self.card(from:)).sorted(by: Self.severityFirst)
            errorMessage = nil
        } catch {
            errorMessage = "读取主机失败：\(error.localizedDescription)"
            cards = []
        }
    }

    /// 下拉刷新。
    ///
    /// v1.0 Phase 7 接入真实 SSH 采集后，这里会触发 `MonitorScheduler` 全量巡检；
    /// 当前仅重读本地数据。
    func refresh() async {
        load()
        lastScanAt = Date()
    }

    // MARK: - 映射

    private static func card(from host: Host) -> HealthCard.Model {
        HealthCard.Model(
            id: host.id,
            name: host.name,
            address: host.displayAddress,
            status: presentationStatus(host.status),
            issue: host.status == .offline ? "上次连接失败，下拉重试" : nil
        )
    }

    /// 领域状态 → 展示状态。
    private static func presentationStatus(_ status: Host.HealthStatus) -> ConnHealthStatus {
        switch status {
        case .ok: .ok
        case .warn: .warn
        case .crit: .crit
        case .offline: .offline
        case .unknown: .unknown
        }
    }

    /// 异常主机置顶（PRD §5.4：仪表盘首页红黄绿，故障优先可见）。
    private static func severityFirst(_ lhs: HealthCard.Model, _ rhs: HealthCard.Model) -> Bool {
        func rank(_ status: ConnHealthStatus) -> Int {
            switch status {
            case .crit: 0
            case .offline: 1
            case .warn: 2
            case .unknown: 3
            case .ok: 4
            }
        }
        let (left, right) = (rank(lhs.status), rank(rhs.status))
        return left == right ? lhs.name < rhs.name : left < right
    }
}
