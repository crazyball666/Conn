import Foundation
import Testing
@testable import ConnUI

/// 覆盖 `HealthCard.accessibilityDescription(for:)` 的口播拼装：
/// 「重连中」/「采集中…」曾各自独立判断，`isBusy == true && loadState == .loading`
/// （每台主机首次采集必经）会撞出「采集中…，采集中…」的重复朗读。
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
            loadState: .loaded, isBusy: true, isReconnecting: true
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("重连中"), in: text) == 1)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
    }

    /// 首次采集：`isBusy == true` 且 `loadState == .loading`——
    /// `MonitorScheduler.attempt` 对无读数的主机恒置 `.collecting`，
    /// `.loading` 的条件正是 `metrics == nil`，两者必然同时成立。
    /// 这是本次修复要锁住的回归场景：修复前会重复 append「采集中…」两次。
    @Test("首采（busy + loading）：「采集中…」只念一次")
    func firstScanCollecting() {
        let model = HealthCard.Model(
            id: "2", name: "loading-host", address: "root@10.0.0.9",
            status: .unknown, loadState: .loading, isBusy: true
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("采集中…"), in: text) == 1)
    }

    @Test("已加载且在后台刷新：先念「采集中…」，再念当前读数")
    func loadedWhileRefreshing() {
        let model = HealthCard.Model(
            id: "3", name: "db-master", address: "root@10.0.0.2",
            status: .ok, cpu: 8, memory: 38, disk: 68,
            loadState: .loaded, isBusy: true
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("采集中…"), in: text) == 1)
        #expect(text.contains("CPU 8%"))
        #expect(text.contains("内存 38%"))
        #expect(text.contains("磁盘 68%"))
        // 顺序：「采集中…」出现在读数之前，让用户先建立「这批数字可能马上更新」的预期。
        let collectingRange = text.range(of: L("采集中…"))
        let cpuRange = text.range(of: "CPU 8%")
        #expect(collectingRange != nil && cpuRange != nil)
        if let collectingRange, let cpuRange {
            #expect(collectingRange.upperBound <= cpuRange.lowerBound)
        }
    }

    @Test("失败：念错误文案，不带「采集中…」")
    func failed() {
        let model = HealthCard.Model(
            id: "4", name: "db-master", address: "root@10.0.0.2",
            status: .offline, loadState: .failed("连接超时：22 端口无响应")
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(text.contains("连接超时：22 端口无响应"))
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
    }

    @Test("正常已加载：只念状态与读数，不带「采集中…」「重连中」")
    func loadedIdle() {
        let model = HealthCard.Model(
            id: "5", name: "hk", address: "root@10.0.0.1",
            status: .ok, cpu: 8, memory: 38, disk: 68,
            loadState: .loaded
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
        #expect(occurrences(of: L("重连中"), in: text) == 0)
        #expect(text.contains("CPU 8%"))
        #expect(text.contains("内存 38%"))
        #expect(text.contains("磁盘 68%"))
    }
}
