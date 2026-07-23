import ConnMonitor
import ConnSSH
import Foundation

/// 演示模式的假指标发生器（技术方案 §4.10：正弦+噪声，含一台故障机）。
///
/// 关键点：CPU 利用率靠两次 `/proc/stat` 差分得出，故必须**跨调用累加、单调递增**
/// 的 jiffies——每次调用把 total 加固定步长、idle 只加 `(1-cpu)` 那份，
/// 相邻两次差分正好还原目标 cpu。用锁保护每主机累计量，`@unchecked Sendable`。
final class DemoMetricsEngine: @unchecked Sendable {
    private struct State {
        var total: Int64
        var idle: Int64
        var rx: Int64
        var tx: Int64
        var tick: Int
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]

    /// 生成一台主机一次采集的 sentinel 分段输出。
    func metricOutput(for endpoint: SSHEndpoint) -> String {
        lock.lock()
        defer { lock.unlock() }

        let fault = endpoint.host == DemoData.faultHostAddress
        var state = states[endpoint.host]
            ?? State(total: 400_000, idle: 300_000, rx: 5_000_000, tx: 3_000_000, tick: 0)
        let phase = Double(abs(endpoint.host.hashValue) % 360)
        let cpu = fault ? 0.94 : clamp(0.32 + 0.22 * sin(Double(state.tick) / 6 + phase), 0.04, 0.9)
        let mem = fault ? 0.92 : clamp(0.45 + 0.18 * sin(Double(state.tick) / 9 + phase + 1), 0.2, 0.88)
        let disk = fault ? 0.90 : clamp(0.40 + 0.003 * Double(abs(endpoint.host.hashValue) % 100), 0.25, 0.85)

        let step: Int64 = 400
        state.total += step
        state.idle += Int64(Double(step) * (1 - cpu))
        state.rx += Int64(80_000 + 140_000 * (0.5 + 0.5 * sin(Double(state.tick) / 4 + phase)))
        state.tx += Int64(40_000 + 90_000 * (0.5 + 0.5 * sin(Double(state.tick) / 5 + phase)))
        state.tick += 1
        states[endpoint.host] = state

        return render(state: state, cpu: cpu, mem: mem, disk: disk, load1: cpu * 4)
    }

    // MARK: - 渲染各段

    private func render(state: State, cpu: Double, mem: Double, disk: Double, load1: Double) -> String {
        let sentinel = CollectionScript.Sentinel.self
        return [
            sentinel.stat, statLine(total: state.total, idle: state.idle),
            sentinel.mem, memLines(usedFraction: mem),
            sentinel.load, String(format: "%.2f %.2f %.2f 2/431 12345", load1, load1 * 0.9, load1 * 0.8),
            sentinel.disk, diskLines(usedFraction: disk),
            sentinel.net, netLines(rx: state.rx, tx: state.tx),
            sentinel.uptime, "864000.42 3456789.10",
            sentinel.ps, psLines(cpu: cpu, mem: mem),
            sentinel.top, "",
            sentinel.end
        ].joined(separator: "\n")
    }

    private func statLine(total: Int64, idle: Int64) -> String {
        let busy = max(0, total - idle)
        let user = Int64(Double(busy) * 0.7)
        let system = busy - user
        return "cpu  \(user) 0 \(system) \(idle) 0 0 0 0 0 0"
    }

    private func memLines(usedFraction: Double) -> String {
        let totalKB = 8_000_000
        let available = Int(Double(totalKB) * (1 - usedFraction))
        return """
        MemTotal:        \(totalKB) kB
        MemFree:         \(available / 2) kB
        MemAvailable:    \(available) kB
        Buffers:         120000 kB
        Cached:          900000 kB
        """
    }

    private func diskLines(usedFraction: Double) -> String {
        let blocks = 41_152_000
        let used = Int(Double(blocks) * usedFraction)
        let available = blocks - used
        let capacity = Int(usedFraction * 100)
        return """
        Filesystem     1024-blocks     Used Available Capacity Mounted on
        /dev/vda1         \(blocks) \(used)  \(available)      \(capacity)% /
        """
    }

    private func netLines(rx: Int64, tx: Int64) -> String {
        """
        Inter-|   Receive                    |  Transmit
         face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed
            lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0
          eth0: \(rx) 40000 0 0 0 0 0 0 \(tx) 35000 0 0 0 0 0 0
        """
    }

    private func psLines(cpu: Double, mem: Double) -> String {
        let procs: [(pid: Int, name: String, cpuMul: Double, memMul: Double)] = [
            (812, "nginx", 46, 6),
            (1043, "mysqld", 31, 22),
            (655, "redis-server", 14, 4),
            (1187, "node", 22, 11),
            (98, "python3", 9, 8)
        ]
        let rows = procs
            .map { (pid: $0.pid, name: $0.name, cpu: min(99, cpu * $0.cpuMul), mem: min(99, mem * $0.memMul)) }
            .sorted { $0.cpu > $1.cpu }
            .map { String(format: "%7d %4.1f %4.1f %@", $0.pid, $0.cpu, $0.mem, $0.name) }
        return (["    PID %CPU %MEM COMMAND"] + rows).joined(separator: "\n")
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
