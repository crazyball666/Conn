import Testing
@testable import ConnMonitor

struct CPUCalculatorTests {
    @Test("两次差分求利用率")
    func usageFromDiff() {
        let previous = CPUJiffies(total: 1000, idle: 900)
        let current = CPUJiffies(total: 1185, idle: 1020)
        // totalDelta=185, idleDelta=120, busy=65 → 65/185*100 ≈ 35.135
        let usage = CPUCalculator.usage(previous: previous, current: current)
        #expect(usage != nil)
        #expect(abs((usage ?? 0) - 35.135135) < 0.0001)
    }

    @Test("总时间无增量 → nil（不显示错值）")
    func noDelta() {
        let snapshot = CPUJiffies(total: 1000, idle: 900)
        #expect(CPUCalculator.usage(previous: snapshot, current: snapshot) == nil)
    }

    @Test("满载：空闲无增长 → 100%")
    func fullyBusy() {
        let previous = CPUJiffies(total: 1000, idle: 500)
        let current = CPUJiffies(total: 1100, idle: 500)
        #expect(CPUCalculator.usage(previous: previous, current: current) == 100)
    }
}

struct HealthEvaluatorTests {
    @Test("全在阈值内 → ok")
    func allOK() {
        #expect(HealthEvaluator.severity(cpu: 30, mem: 40, disk: 50) == .ok)
    }

    @Test("越警戒线 → warn")
    func warn() {
        #expect(HealthEvaluator.severity(cpu: 85, mem: 40, disk: 50) == .warn)
    }

    @Test("越危险线 → crit（取最严重）")
    func crit() {
        #expect(HealthEvaluator.severity(cpu: 85, mem: 95, disk: 50) == .crit)
    }

    @Test("全缺失 → unknown")
    func unknown() {
        #expect(HealthEvaluator.severity(cpu: nil, mem: nil, disk: nil) == .unknown)
    }
}
