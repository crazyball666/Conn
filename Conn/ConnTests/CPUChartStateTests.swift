import ConnMonitor
import Testing
@testable import Conn

@Suite("CPU 图表状态")
struct CPUChartStateTests {
    @Test("八个指标默认全部显示，切换只影响目标指标")
    func visibilityToggle() {
        var visibility = CPUChartVisibility()
        #expect(visibility.visible == Set(CPUChartMetric.allCases))

        visibility.toggle(.system)
        #expect(!visibility.contains(.system))
        #expect(visibility.contains(.user))

        visibility.toggle(.system)
        #expect(visibility.contains(.system))
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
}
