// 仅 DEBUG 编译：演示/截图/冒烟数据源，不进入发行包。
#if DEBUG
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
        var ioRead: Int64
        var ioWrite: Int64
        var tick: Int
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]

    /// 生成一台主机一次采集的 sentinel 分段输出。
    func metricOutput(for endpoint: SSHEndpoint, includeExtended: Bool = true) -> String {
        lock.lock()
        defer { lock.unlock() }

        let fault = endpoint.host == DemoData.faultHostAddress
        var state = states[endpoint.host]
            ?? State(total: 400_000, idle: 300_000, rx: 5_000_000, tx: 3_000_000,
                     ioRead: 40_000_000, ioWrite: 22_000_000, tick: 0)
        let phase = Double(abs(endpoint.host.hashValue) % 360)
        let cpu = fault ? 0.94 : clamp(0.32 + 0.22 * sin(Double(state.tick) / 6 + phase), 0.04, 0.9)
        let mem = fault ? 0.92 : clamp(0.45 + 0.18 * sin(Double(state.tick) / 9 + phase + 1), 0.2, 0.88)
        let disk = fault ? 0.90 : clamp(0.40 + 0.003 * Double(abs(endpoint.host.hashValue) % 100), 0.25, 0.85)

        let step: Int64 = 400
        state.total += step
        state.idle += Int64(Double(step) * (1 - cpu))
        state.rx += Int64(80_000 + 140_000 * (0.5 + 0.5 * sin(Double(state.tick) / 4 + phase)))
        state.tx += Int64(40_000 + 90_000 * (0.5 + 0.5 * sin(Double(state.tick) / 5 + phase)))
        // IO 扇区累加（512B/扇区）：读 ~1.5MB/s、写 ~0.8MB/s 上下浮动。
        state.ioRead += Int64(3_000 + 2_400 * (0.5 + 0.5 * sin(Double(state.tick) / 6 + phase)))
        state.ioWrite += Int64(1_600 + 1_200 * (0.5 + 0.5 * sin(Double(state.tick) / 7 + phase)))
        state.tick += 1
        states[endpoint.host] = state

        return render(
            state: state, cpu: cpu, mem: mem, disk: disk,
            includeExtended: includeExtended
        )
    }

    /// 生成进程专用采集命令的输出，不推进基础指标的差分状态。
    func processOutput(for endpoint: SSHEndpoint) -> String {
        lock.lock()
        defer { lock.unlock() }

        let fault = endpoint.host == DemoData.faultHostAddress
        let state = states[endpoint.host]
            ?? State(total: 400_000, idle: 300_000, rx: 5_000_000, tx: 3_000_000,
                     ioRead: 40_000_000, ioWrite: 22_000_000, tick: 0)
        let phase = Double(abs(endpoint.host.hashValue) % 360)
        let cpu = fault ? 0.94 : clamp(0.32 + 0.22 * sin(Double(state.tick) / 6 + phase), 0.04, 0.9)
        let mem = fault ? 0.92 : clamp(0.45 + 0.18 * sin(Double(state.tick) / 9 + phase + 1), 0.2, 0.88)
        let sentinel = ProcessCollectionScript.Sentinel.self
        return [
            sentinel.ps, psLines(cpu: cpu, mem: mem),
            sentinel.top, "", sentinel.end
        ].joined(separator: "\n")
    }

    // MARK: - 渲染各段

    private func render(
        state: State,
        cpu: Double,
        mem: Double,
        disk: Double,
        includeExtended: Bool
    ) -> String {
        let sentinel = CollectionScript.Sentinel.self
        let load1 = cpu * 4
        var lines = [
            sentinel.stat, statLine(total: state.total, idle: state.idle, cpu: cpu),
            sentinel.mem, memLines(usedFraction: mem),
            sentinel.load, String(format: "%.2f %.2f %.2f 2/431 12345", load1, load1 * 0.9, load1 * 0.8),
            sentinel.disk, diskLines(usedFraction: disk),
            sentinel.net, netLines(rx: state.rx, tx: state.tx),
            sentinel.io, diskstatsLine(read: state.ioRead, write: state.ioWrite),
            // uptime 随 tick 递增(≈3s/次),让相邻样本可差分出网络/IO 速率。
            sentinel.uptime, String(format: "%.2f 3456789.10", 864_000 + Double(state.tick) * 3)
        ]
        if includeExtended {
            lines += [
                sentinel.snmp, snmpLines,
                sentinel.ipaddr, ipLines,
                sentinel.os, "PRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\nID=ubuntu\nVERSION_ID=\"24.04\"",
                sentinel.cpuinfo, "model name\t: Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz"
            ]
        }
        lines.append(sentinel.end)
        return lines.joined(separator: "\n")
    }

    private func statLine(total: Int64, idle: Int64, cpu: Double) -> String {
        let busy = max(0, total - idle)
        // 汇总行按运维常见构成分配 busy：用户/系统/iowait/irq/softirq/steal。
        let user = Int64(Double(busy) * 0.55)
        let system = Int64(Double(busy) * 0.22)
        let iowait = Int64(Double(busy) * 0.10)
        let irq = Int64(Double(busy) * 0.03)
        let softirq = Int64(Double(busy) * 0.05)
        let steal = max(0, busy - user - system - iowait - irq - softirq)
        // 汇总行 + 4 个逻辑核行。各核围绕总体使用率上下偏移 → 折线可区分。
        // coreIdle 按 coreTotal 比例给出,故相邻样本差分正好还原每核目标使用率。
        let aggregate = "cpu  \(user) 0 \(system) \(idle) \(iowait) \(irq) \(softirq) \(steal) 0 0"
        let coreTotal = total / 4
        let cores = (0 ..< 4).map { index -> String in
            let target = min(0.99, max(0.02, cpu + (Double(index) - 1.5) * 0.04))
            let coreIdle = Int64(Double(coreTotal) * (1 - target))
            let coreBusy = coreTotal - coreIdle
            let coreUser = Int64(Double(coreBusy) * 0.7)
            return "cpu\(index) \(coreUser) 0 \(coreBusy - coreUser) \(coreIdle) 0 0 0 0 0 0"
        }
        return ([aggregate] + cores).joined(separator: "\n")
    }

    /// `/proc/diskstats` 一行（vda 整盘）：第 6 列扇区读、第 10 列扇区写。
    private func diskstatsLine(read: Int64, write: Int64) -> String {
        "252       0 vda 100000 0 \(read) 50000 80000 0 \(write) 40000 0 30000 90000"
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
        SwapTotal:       2000000 kB
        SwapFree:        1500000 kB
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
            lo: 282000 100 0 0 0 0 0 0 282000 100 0 0 0 0 0 0
          eth0: \(rx) 40000 0 0 0 0 0 0 \(tx) 35000 0 0 0 0 0 0
        br-70fa8e: \(rx / 6) 800 0 0 0 0 0 0 \(tx / 9) 600 0 0 0 0 0 0
        docker0: 12000 20 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        """
    }

    /// /proc/net/snmp 的 Tcp 行（表头 + 值）。重传率 = RetransSegs/OutSegs ≈ 0.24%。
    private let snmpLines = """
    Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
    Tcp: 1 200 120000 -1 1848 25000 1785 3000 42 5100000 5000000 12000 0 8000 0
    """

    /// ip -o -4 addr show 输出（网卡 → IPv4）。
    private let ipLines = """
    1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever
    2: eth0    inet 38.147.173.228/24 brd 38.147.173.255 scope global eth0\\       valid_lft forever preferred_lft forever
    3: br-70fa8e    inet 172.19.0.1/16 brd 172.19.255.255 scope global br-70fa8e\\       valid_lft forever preferred_lft forever
    4: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\\       valid_lft forever preferred_lft forever
    """

    private struct ProcSpec {
        let pid: Int
        let ppid: Int
        let user: String
        let cpuMul: Double
        let memMul: Double
        let rssKB: Int
        let threads: Int
        let state: String
        let etimes: Int
        let args: String
    }

    private struct DemoProc {
        let spec: ProcSpec
        let cpu: Double
        let mem: Double
    }

    /// 输出新版 `ps -eo pid,ppid,user,pcpu,pmem,rss,nlwp,stat,etimes,args` 格式，
    /// 覆盖典型运维进程（Web/DB/缓存/运行时/容器/内核线程），字段随主机负载浮动。
    private func psLines(cpu: Double, mem: Double) -> String {
        let specs = [
            ProcSpec(pid: 812, ppid: 1, user: "root", cpuMul: 6, memMul: 2,
                     rssKB: 18_400, threads: 1, state: "Ss", etimes: 864_000,
                     args: "nginx: master process /usr/sbin/nginx -g daemon on;"),
            ProcSpec(pid: 815, ppid: 812, user: "www-data", cpuMul: 46, memMul: 6,
                     rssKB: 96_200, threads: 4, state: "S", etimes: 863_400,
                     args: "nginx: worker process"),
            ProcSpec(pid: 1043, ppid: 1, user: "mysql", cpuMul: 31, memMul: 22,
                     rssKB: 1_638_400, threads: 34, state: "Sl", etimes: 820_000,
                     args: "/usr/sbin/mysqld"),
            ProcSpec(pid: 1187, ppid: 1, user: "deploy", cpuMul: 22, memMul: 11,
                     rssKB: 512_000, threads: 12, state: "Sl", etimes: 172_800,
                     args: "node /srv/app/server.js"),
            ProcSpec(pid: 1502, ppid: 1, user: "appuser", cpuMul: 18, memMul: 26,
                     rssKB: 2_097_152, threads: 48, state: "Sl", etimes: 259_200,
                     args: "java -Xmx2g -jar /srv/gateway.jar"),
            ProcSpec(pid: 655, ppid: 1, user: "redis", cpuMul: 14, memMul: 4,
                     rssKB: 128_000, threads: 5, state: "Sl", etimes: 604_800,
                     args: "redis-server *:6379"),
            ProcSpec(pid: 1301, ppid: 1, user: "postgres", cpuMul: 11, memMul: 9,
                     rssKB: 220_000, threads: 1, state: "Ss", etimes: 700_000,
                     args: "postgres: 15/main: writer process"),
            ProcSpec(pid: 98, ppid: 1, user: "root", cpuMul: 9, memMul: 8,
                     rssKB: 82_000, threads: 3, state: "S", etimes: 500_000,
                     args: "/usr/bin/python3 /opt/agent/monitor.py"),
            ProcSpec(pid: 720, ppid: 1, user: "root", cpuMul: 7, memMul: 7,
                     rssKB: 92_000, threads: 14, state: "Ssl", etimes: 864_000,
                     args: "/usr/bin/dockerd -H fd://"),
            ProcSpec(pid: 688, ppid: 1, user: "root", cpuMul: 5, memMul: 5,
                     rssKB: 64_000, threads: 10, state: "Ssl", etimes: 864_000,
                     args: "/usr/bin/containerd"),
            ProcSpec(pid: 900, ppid: 1, user: "root", cpuMul: 2, memMul: 1,
                     rssKB: 12_800, threads: 1, state: "Ss", etimes: 864_000,
                     args: "sshd: /usr/sbin/sshd -D"),
            ProcSpec(pid: 1, ppid: 0, user: "root", cpuMul: 1, memMul: 1,
                     rssKB: 11_200, threads: 1, state: "Ss", etimes: 864_000,
                     args: "/sbin/init"),
            ProcSpec(pid: 600, ppid: 1, user: "root", cpuMul: 1, memMul: 1,
                     rssKB: 4_100, threads: 1, state: "Ss", etimes: 864_000,
                     args: "/usr/sbin/cron -f"),
            ProcSpec(pid: 12, ppid: 2, user: "root", cpuMul: 3, memMul: 0,
                     rssKB: 0, threads: 1, state: "I", etimes: 864_000,
                     args: "[kworker/0:1-events]")
        ]
        let rows = specs
            .map { DemoProc(spec: $0, cpu: min(99, cpu * $0.cpuMul), mem: min(99.9, mem * $0.memMul)) }
            .sorted { $0.cpu > $1.cpu }
            .map { row in
                let spec = row.spec
                return String(
                    format: "%d %d %@ %.1f %.1f %d %d %@ %d %@",
                    spec.pid, spec.ppid, spec.user, row.cpu, row.mem,
                    spec.rssKB, spec.threads, spec.state, spec.etimes, spec.args
                )
            }
        return (["  PID  PPID USER      %CPU %MEM   RSS NLWP STAT ELAPSED COMMAND"] + rows).joined(separator: "\n")
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
#endif
