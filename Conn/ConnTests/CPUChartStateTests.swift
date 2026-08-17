import ConnMonitor
import Testing
@testable import Conn

@Suite("CPU 图表状态")
struct CPUChartStateTests {
    @Test("内存已用、缓存、空闲分别使用远端实际值，不强行补成 100%")
    func memorySeriesKeepIndependentActualValues() throws {
        let metrics = HostMetrics(
            hostID: "memory",
            cpu: nil,
            mem: 40,
            memTotalBytes: 1_000,
            memUsedBytes: 400,
            memBuffersCache: 350,
            memFree: 100,
            disk: nil,
            load1: nil,
            netRx: nil,
            netTx: nil,
            uptimeSeconds: nil,
            severity: .unknown
        )

        let values = try #require(MemoryChartValues(metrics: metrics))
        #expect(values.used == 40)
        #expect(values.cache == 35)
        #expect(values.free == 10)
    }

    @Test("趋势图 Y 轴固定生成五个等距刻度")
    func chartHasFiveExactYAxisValues() {
        #expect(MetricTrendChart.axisValues(in: 0 ... 100) == [0, 25, 50, 75, 100])
        #expect(MetricTrendChart.axisValues(in: 0 ... 1024) == [0, 256, 512, 768, 1024])
    }

    @Test("趋势图保留一个屏外样本再平滑移出可视窗口")
    func chartKeepsOneOverscanSample() {
        #expect(TrendViewport.visibleSampleCount == 40)
        #expect(TrendViewport.retainedSampleCount == 41)
        #expect(TrendViewport.xDomain(endingAt: 39) == 0 ... 39)
        #expect(TrendViewport.xDomain(endingAt: 40) == 1 ... 40)
    }

    @Test("CPU 八个分类默认全部显示")
    func visibilityToggle() {
        var visibility = CPUChartVisibility()
        #expect(visibility.visible == Set(CPUChartMetric.allCases))
        #expect(visibility.contains(.idle))

        visibility.toggle(.system)
        #expect(!visibility.contains(.system))
        #expect(visibility.contains(.user))

        visibility.toggle(.system)
        #expect(visibility.contains(.system))

        // 空闲和其它分类一样可以独立隐藏、恢复。
        visibility.toggle(.idle)
        #expect(!visibility.contains(.idle))
        visibility.toggle(.idle)
        #expect(visibility.contains(.idle))
    }

    @Test("八类 CPU 时间分别进入自己的历史")
    func independentHistories() {
        var history = CPUCategoryHistory()
        history.append(
            CPUBreakdown(
                user: 1, system: 2, iowait: 3, nice: 4,
                irq: 5, softirq: 6, steal: 7, idle: 72
            ),
            limit: 40
        )

        #expect(history[.user] == [1])
        #expect(history[.system] == [2])
        #expect(history[.iowait] == [3])
        #expect(history[.idle] == [72])
        #expect(history[.nice] == [4])
        #expect(history[.irq] == [5])
        #expect(history[.softirq] == [6])
        #expect(history[.steal] == [7])
    }

    @Test("滚动窗口裁剪后仍保留采样的稳定序号")
    func keepsStableSampleSequenceWhenTrimming() {
        var history = CPUCategoryHistory()
        let breakdown = CPUBreakdown(
            user: 1, system: 2, iowait: 3, nice: 4,
            irq: 5, softirq: 6, steal: 7, idle: 72
        )

        for sequence in 0 ... 40 {
            history.append(breakdown, sequence: sequence, limit: TrendViewport.retainedSampleCount)
        }

        // 0 已经在下一次平移时准备离开左边界，必须保留到它真正移出屏幕后再裁剪。
        #expect(history.samples(for: .user).map(\.sequence) == Array(0 ... 40))

        history.append(breakdown, sequence: 41, limit: TrendViewport.retainedSampleCount)
        #expect(history.samples(for: .user).map(\.sequence) == Array(1 ... 41))
        #expect(history.samples(for: .user).map(\.value) == Array(repeating: 1, count: 41))
    }
}
