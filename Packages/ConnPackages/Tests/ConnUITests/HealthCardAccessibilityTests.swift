import Foundation
import Testing
@testable import ConnUI

/// 覆盖 `HealthCard.accessibilityDescription(for:)` 的口播拼装：连接状态和健康状态
/// 要保持稳定，后台指标采集过程不进入状态区域。
@Suite("HealthCard — 无障碍口播拼装")
struct HealthCardAccessibilityTests {
    /// 统计子串在字符串中出现的次数（不重叠）。
    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    @Test("重连中：只念一次「重连中」，不再念「采集中…」")
    func reconnecting() {
        let model = HealthCard.Model(
            id: "1", name: "hk", address: "root@10.0.0.1",
            status: .ok, cpu: 12, memory: 40, disk: 55,
            loadState: .loaded, connectionPhase: .reconnecting, collectPhase: .reconnecting
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("重连中"), in: text) == 1)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)

        let unknownModel = HealthCard.Model(
            id: "1b", name: "unknown-reconnecting", address: "root@10.0.0.10",
            status: .unknown, loadState: .loading, connectionPhase: .reconnecting,
            collectPhase: .reconnecting
        )
        let unknownText = HealthCard.accessibilityDescription(for: unknownModel)
        #expect(occurrences(of: L("重连中"), in: unknownText) == 1)
        #expect(occurrences(of: L("连接中…"), in: unknownText) == 0)
    }

    /// 首次采集：后台可能已经进入 `.collecting`，但 SSH 连接态必须明确是
    /// `.connecting`；两个维度可以同时存在，不能让采集态冒充连接态。
    /// 首次连接没有健康读数时，不能把正常的连接过程播报成「未知」；
    /// 也不应再重复播报「连接中」和「采集中」。
    @Test("首采（collecting + loading）：播报连接中而不是未知")
    func firstScanCollecting() {
        let model = HealthCard.Model(
            id: "2", name: "loading-host", address: "root@10.0.0.9",
            status: .unknown, loadState: .loading, connectionPhase: .connecting,
            collectPhase: .collecting
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("连接中…"), in: text) == 1)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
        #expect(!text.contains(L("未知")))
    }

    /// 覆盖缺口：连接态明确为 `.connecting`，但后台 `collectPhase` 仍为默认 `.idle`——
    /// `HealthCard.swift` 自带的 `#Preview`（`id: "2"`，`loading-host`）就是这张卡，
    /// 可达且常见（例如首次进入服务器页、还没收到过任何采集结果时）。
    /// 即使采集阶段事件还没来得及写入，独立连接态也足以说明正在建立连接。
    @Test("首采（仅 loading，不在采集）：仍播报连接中")
    func loadingWithoutBusy() {
        let model = HealthCard.Model(
            id: "2", name: "loading-host", address: "root@10.0.0.9",
            status: .unknown, loadState: .loading, connectionPhase: .connecting
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("连接中…"), in: text) == 1)
        #expect(!text.contains(L("未知")))
    }

    @Test("已加载且在后台刷新：不显示采集状态，只念连接正常与读数")
    func loadedWhileRefreshing() {
        let model = HealthCard.Model(
            id: "3", name: "db-master", address: "root@10.0.0.2",
            status: .ok, cpu: 8, memory: 38, disk: 68,
            loadState: .loaded, connectionPhase: .connected, collectPhase: .collecting
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
        #expect(occurrences(of: L("正常"), in: text) == 1)
        #expect(text.contains("CPU 8%"))
        #expect(text.contains("内存 38%"))
        #expect(text.contains("磁盘 68%"))
    }

    @Test("SSH 已连接但健康指标不完整：仍播报正常，不出现未知")
    func loadedPartialHealthStillReportsConnected() {
        let model = HealthCard.Model(
            id: "3b", name: "linux-baseline", address: "root@10.0.0.3",
            status: .unknown, memory: 40, disk: 50,
            loadState: .loaded, connectionPhase: .connected, collectPhase: .collecting
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("连接中…"), in: text) == 0)
        #expect(occurrences(of: L("正常"), in: text) == 1)
        #expect(occurrences(of: L("未知"), in: text) == 0)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
    }

    @Test("失败：念错误文案，不带「采集中…」")
    func failed() {
        let model = HealthCard.Model(
            id: "4", name: "db-master", address: "root@10.0.0.2",
            status: .offline, loadState: .failed("连接超时：22 端口无响应"), connectionPhase: .failed
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(text.contains("连接超时：22 端口无响应"))
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
    }

    /// 覆盖 `collectPhase == .collecting` 且 `loadState == .failed` ——故障主机重试的那一轮。
    /// 采集是后台工作，连接状态区域仍只表达连接/健康状态，不显示采集过程。
    @Test("失败但正在采集（collecting + failed）：只念错误文案")
    func retryingAfterFailure() {
        let model = HealthCard.Model(
            id: "6", name: "db-master", address: "root@10.0.0.2",
            status: .offline, loadState: .failed("连接超时：22 端口无响应"),
            connectionPhase: .failed,
            collectPhase: .collecting
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
        #expect(text.contains("连接超时：22 端口无响应"))
    }

    @Test("正常已加载：只念状态与读数，不带「采集中…」「重连中」")
    func loadedIdle() {
        let model = HealthCard.Model(
            id: "5", name: "hk", address: "root@10.0.0.1",
            status: .ok, cpu: 8, memory: 38, disk: 68,
            loadState: .loaded, connectionPhase: .connected
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
        #expect(occurrences(of: L("重连中"), in: text) == 0)
        #expect(text.contains("CPU 8%"))
        #expect(text.contains("内存 38%"))
        #expect(text.contains("磁盘 68%"))
    }
}
