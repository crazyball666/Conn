import Foundation
import SwiftUI
import Testing
@testable import ConnUI

@Suite("ConnLoadScale — 负载色标")
struct ConnLoadScaleTests {
    /// 停靠点在 0…1 上单调不减，且首尾正好覆盖满量程。
    /// 顺序错了会让渐变出现回折，是这类表驱动代码最容易出的错。
    @Test("停靠点单调且铺满 0…1")
    func stopsAreMonotonicAndFull() {
        let locations = ConnLoadScale.stops.map(\.location)
        #expect(locations == locations.sorted())
        #expect(locations.first == 0)
        #expect(locations.last == 1)
    }

    /// 停靠点必须取自 ConnThreshold，不能写字面量——那组阈值同时被
    /// HealthEvaluator 用于健康判定，写死会在调阈值时静默漂移，
    /// 造成「环已经变金但胶囊还说正常」。
    @Test("停靠点对齐 ConnThreshold")
    func stopsAlignWithThresholds() {
        let locations = ConnLoadScale.stops.map(\.location)
        #expect(locations.contains(ConnThreshold.calm / 100))
        #expect(locations.contains(ConnThreshold.warn / 100))
        #expect(locations.contains(ConnThreshold.crit / 100))
    }

    /// 低载平台期：0 与 calm 两个停靠点必须同色，否则 0–60 段不是恒定绿。
    @Test("低载段两端同色")
    func calmRangeIsFlat() {
        let first = ConnLoadScale.stops[0]
        let calm = ConnLoadScale.stops[1]
        #expect(first.location == 0)
        #expect(calm.location == ConnThreshold.calm / 100)
        #expect(first.color == calm.color)
    }

    /// 高载封顶：crit 与 1.0 两个停靠点必须同色。
    @Test("高载段两端同色")
    func critRangeIsFlat() {
        let crit = ConnLoadScale.stops[3]
        let last = ConnLoadScale.stops[4]
        #expect(crit.location == ConnThreshold.crit / 100)
        #expect(last.location == 1)
        #expect(crit.color == last.color)
    }

    /// 三个可变色槽位的颜色必须分别是绿/黄/红——这是「低=绿、高=红」这条
    /// 设计结论在本文件里唯一的直接颜色断言。上面几条测试都只看 location、
    /// 或只断言「两端相等」，把 stops 的颜色全部错改成同一种颜色（例如全绿）
    /// 也能通过：纯绿的两端自然相等，位置也没变。这里按下标钉死每个槽位
    /// 该是哪个颜色，并顺带钉死 `stops.count`（缩短数组会在别处变成越界
    /// 崩溃而不是测试失败）与 warn 槽位对应的具体下标（`contains` 不保证
    /// 是哪个槽位命中）。
    @Test("槽位颜色与阈值对应：绿/黄/红三色不同")
    func stopsColorsMatchSeverity() {
        #expect(ConnLoadScale.stops.count == 5)
        #expect(ConnLoadScale.stops[1].color == .connGood)
        #expect(ConnLoadScale.stops[2].color == .connWarn)
        #expect(ConnLoadScale.stops[3].color == .connCrit)
        #expect(ConnLoadScale.stops[2].location == ConnThreshold.warn / 100)
    }

    /// gradient 必须由 stops 派生，否则两者会漂移成两套配色。
    @Test("gradient 的停靠位置与 stops 一致")
    func gradientMatchesStops() {
        let actual = ConnLoadScale.gradient.stops.map { Double($0.location) }
        let expected = ConnLoadScale.stops.map(\.location)
        #expect(actual.count == expected.count)
        for (lhs, rhs) in zip(actual, expected) {
            #expect(abs(lhs - rhs) < 0.0001)
        }
    }
}
