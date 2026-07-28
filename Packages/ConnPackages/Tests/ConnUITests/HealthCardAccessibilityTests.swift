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

    /// 覆盖缺口：`loadState == .loading` 且 `isBusy` 为默认值 `false`——
    /// `HealthCard.swift` 自带的 `#Preview`（`id: "2"`，`loading-host`）就是这张卡，
    /// 可达且常见（例如首次进入服务器页、还没收到过任何采集结果时）。
    /// 判断「是否念一次采集中」的条件是析取 `isBusy || loadState == .loading`，
    /// 若被误改成只剩 `isBusy`，这个组合会导致「采集中…」整句消失——本测试锁住它。
    @Test("首采（仅 loading，不 busy）：仍念一次「采集中…」")
    func loadingWithoutBusy() {
        let model = HealthCard.Model(
            id: "2", name: "loading-host", address: "root@10.0.0.9",
            status: .unknown, loadState: .loading
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

    /// 覆盖缺口：`isBusy == true` 且 `loadState == .failed` ——故障主机重试的那一轮。
    /// 可达路径：主机曾采集失败（`metrics` 仍为 nil、上一轮 `errors` 还挂着，
    /// 只有采集成功才会清空），调度器对它发起新一轮采集时会先把它标为
    /// `.collecting`（即此处 `isBusy == true`），但 `loadState` 仍是上一轮遗留的
    /// `.failed`——直到这一轮成功或再次失败才会更新。此时正确的口播顺序是
    /// 「…，采集中…，<上次的失败原因>」：先告知正在重试，再给出上次失败的原因，
    /// 不能颠倒、也不能因为处于失败态就吞掉「采集中…」。
    @Test("失败但正在重试（busy + failed）：先念「采集中…」，再念错误文案")
    func retryingAfterFailure() {
        let model = HealthCard.Model(
            id: "6", name: "db-master", address: "root@10.0.0.2",
            status: .offline, loadState: .failed("连接超时：22 端口无响应"), isBusy: true
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("采集中…"), in: text) == 1)
        #expect(text.contains("连接超时：22 端口无响应"))
        let collectingRange = text.range(of: L("采集中…"))
        let errorRange = text.range(of: "连接超时：22 端口无响应")
        #expect(collectingRange != nil && errorRange != nil)
        if let collectingRange, let errorRange {
            #expect(collectingRange.upperBound <= errorRange.lowerBound)
        }
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
