import Foundation
import Testing
@testable import ConnUI

/// 覆盖 `HealthCard.accessibilityDescription(for:)` 的口播拼装：
/// 「重连中」/「采集中…」曾各自独立判断，`collectPhase == .collecting && loadState == .loading`
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
            loadState: .loaded, collectPhase: .reconnecting
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("重连中"), in: text) == 1)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)

        let unknownModel = HealthCard.Model(
            id: "1b", name: "unknown-reconnecting", address: "root@10.0.0.10",
            status: .unknown, loadState: .loading, collectPhase: .reconnecting
        )
        let unknownText = HealthCard.accessibilityDescription(for: unknownModel)
        #expect(occurrences(of: L("重连中"), in: unknownText) == 1)
        #expect(occurrences(of: L("连接中…"), in: unknownText) == 0)
    }

    /// 首次采集：`collectPhase == .collecting` 且 `loadState == .loading`——
    /// `MonitorScheduler.attempt` 对无读数的主机恒置 `.collecting`，
    /// `.loading` 的条件正是 `metrics == nil`，两者必然同时成立。
    /// 首次连接没有健康读数时，不能把正常的连接过程播报成「未知」；
    /// 也不应再重复播报「连接中」和「采集中」。
    @Test("首采（collecting + loading）：播报连接中而不是未知")
    func firstScanCollecting() {
        let model = HealthCard.Model(
            id: "2", name: "loading-host", address: "root@10.0.0.9",
            status: .unknown, loadState: .loading, collectPhase: .collecting
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("连接中…"), in: text) == 1)
        #expect(occurrences(of: L("采集中…"), in: text) == 0)
        #expect(!text.contains(L("未知")))
    }

    /// 覆盖缺口：`loadState == .loading` 且 `collectPhase` 为默认值 `.idle`——
    /// `HealthCard.swift` 自带的 `#Preview`（`id: "2"`，`loading-host`）就是这张卡，
    /// 可达且常见（例如首次进入服务器页、还没收到过任何采集结果时）。
    /// 即使阶段事件还没来得及写入，loading 本身也足以说明正在建立连接。
    @Test("首采（仅 loading，不在采集）：仍播报连接中")
    func loadingWithoutBusy() {
        let model = HealthCard.Model(
            id: "2", name: "loading-host", address: "root@10.0.0.9",
            status: .unknown, loadState: .loading
        )
        let text = HealthCard.accessibilityDescription(for: model)
        #expect(occurrences(of: L("连接中…"), in: text) == 1)
        #expect(!text.contains(L("未知")))
    }

    @Test("已加载且在后台刷新：先念「采集中…」，再念当前读数")
    func loadedWhileRefreshing() {
        let model = HealthCard.Model(
            id: "3", name: "db-master", address: "root@10.0.0.2",
            status: .ok, cpu: 8, memory: 38, disk: 68,
            loadState: .loaded, collectPhase: .collecting
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

    /// 覆盖缺口：`collectPhase == .collecting` 且 `loadState == .failed` ——故障主机重试的那一轮。
    /// 可达路径：主机曾采集失败（`metrics` 仍为 nil、上一轮 `errors` 还挂着，
    /// 只有采集成功才会清空），调度器对它发起新一轮采集时会先把它标为
    /// `.collecting`，但 `loadState` 仍是上一轮遗留的
    /// `.failed`——直到这一轮成功或再次失败才会更新。此时正确的口播顺序是
    /// 「…，采集中…，<上次的失败原因>」：先告知正在重试，再给出上次失败的原因，
    /// 不能颠倒、也不能因为处于失败态就吞掉「采集中…」。
    @Test("失败但正在重试（collecting + failed）：先念「采集中…」，再念错误文案")
    func retryingAfterFailure() {
        let model = HealthCard.Model(
            id: "6", name: "db-master", address: "root@10.0.0.2",
            status: .offline, loadState: .failed("连接超时：22 端口无响应"),
            collectPhase: .collecting
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
