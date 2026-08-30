// 仅 DEBUG 编译：演示/截图/冒烟数据源，不进入发行包。
#if DEBUG
import ConnKit
import ConnSSH
import ConnStore
import Foundation

/// 演示模式的数据源（技术方案 §4.10）。
///
/// 通过 `MockSSHTransport.dynamicResponder` 把假指标/容器/日志注入 Mock 引擎，
/// 无需任何服务器即可完整体验 Phase 7–9。数据生成逻辑放在 App 层（可 import
/// ConnMonitor/ConnOps），ConnSSH 只持一个闭包插槽，保持分层解耦。
enum DemoData {
    /// 演示故障机地址——指标发生器对它输出高 CPU/内存，仪表盘上呈红色故障态。
    static let faultHostAddress = "10.20.0.66"

    /// 跨调用保留累计量的指标发生器（CPU 差分需要单调递增的 jiffies）。
    private static let metrics = DemoMetricsEngine()

    /// 组装 Mock 行为：指标走动态发生器，日志流带 30ms 节流模拟跟随。
    /// Docker/日志/片段的响应在 Phase 8/9 由 `dockerResponse` / `logResponse` 扩展。
    static func behavior() -> MockSSHTransport.Behavior {
        let shouldFailConnection =
            ProcessInfo.processInfo.environment["CONN_SMOKE_PROCESS_FAILURE"] != nil
        let usesDarwinMetrics =
            ProcessInfo.processInfo.environment["CONN_SMOKE_DARWIN_METRICS"] != nil
        let smokeExecDelay = Int(
            ProcessInfo.processInfo.environment["CONN_SMOKE_EXEC_DELAY_MS"] ?? "0"
        ) ?? 0
        return MockSSHTransport.Behavior(
            failConnect: shouldFailConnection
                ? .connectionRefused(endpoint: SSHEndpoint(host: faultHostAddress))
                : nil,
            dynamicResponder: { command, endpoint in
                if command == RemotePlatformDetector.posixCommand {
                    return .init(stdout: usesDarwinMetrics
                        ? darwinPlatformProfileOutput
                        : platformProfileOutput)
                }
                if let executableResolution = executableResolutionResponse(command) {
                    return executableResolution
                }
                if usesDarwinMetrics, command.contains("__CONN_DARWIN_TOP__") {
                    return .init(stdout: darwinMetricOutput)
                }
                if command.contains("/proc/stat") {
                    // 与生产一致：基础指标与进程使用两条独立命令。
                    return .init(stdout: metrics.metricOutput(
                        for: endpoint,
                        includeExtended: command.contains("os-release")
                    ))
                }
                if command.contains("ps -eo") {
                    return .init(stdout: metrics.processOutput(for: endpoint))
                }
                return DemoOps.response(command: command, endpoint: endpoint)
            },
            execCommandDelay: .milliseconds(smokeExecDelay),
            streamChunkDelay: .milliseconds(30)
        )
    }

    /// Mirrors ConnSSH's framed executable-discovery protocol so Demo exercises
    /// the same login-environment path as real hosts.
    nonisolated private static func executableResolutionResponse(
        _ command: String
    ) -> MockSSHTransport.CommandResponse? {
        let beginPrefix = "__CONN_EXECUTABLES_v1_BEGIN_"
        guard let beginRange = command.range(of: beginPrefix) else { return nil }
        let nonceSuffix = command[beginRange.upperBound...]
        guard let nonceEnd = nonceSuffix.range(of: "__") else { return nil }
        let nonce = String(nonceSuffix[..<nonceEnd.lowerBound])
        guard !nonce.isEmpty else { return nil }

        let executablePrefix = "${conn_dir}/"
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"
        )
        var names: [String] = []
        var remainder = command[...]
        while let range = remainder.range(of: executablePrefix) {
            let suffix = remainder[range.upperBound...]
            let name = String(suffix.prefix {
                $0.unicodeScalars.allSatisfy { allowed.contains($0) }
            })
            if !name.isEmpty, !names.contains(name) { names.append(name) }
            remainder = suffix.dropFirst(name.count)
        }

        let paths = [
            "sh": "/bin/sh",
            "bash": "/bin/bash",
            "zsh": "/bin/zsh",
            "docker": "/usr/bin/docker",
            "docker-compose": "/usr/bin/docker-compose",
        ]
        var lines = [
            "__CONN_EXECUTABLES_v1_BEGIN_\(nonce)__",
            "/usr/bin:/bin",
        ]
        for (index, name) in names.enumerated() {
            lines.append("__CONN_EXECUTABLES_v1_ITEM_\(index)_\(nonce)__")
            lines.append(paths[name] ?? "")
        }
        lines.append("__CONN_EXECUTABLES_v1_END_\(nonce)__")
        return .init(stdout: lines.joined(separator: "\n"))
    }

    /// 与 `RemotePlatformDetector.posixCommand` 的分段协议保持一致。Demo 环境也必须
    /// 走完整的平台探测流程，否则探测器会把缺少 uname 标记的输出当成未知平台，
    /// 继而回退到 PowerShell，导致 Docker 等平台能力在 UI 冒烟测试中被错误禁用。
    nonisolated private static let platformProfileOutput = """
    __CONN_UNAME__
    Linux
    __CONN_RELEASE__
    6.8.0-demo
    __CONN_ARCH__
    arm64
    __CONN_SHELL__
    /bin/bash
    __CONN_END__
    """

    /// Darwin 指标 UI 冒烟画像；用于验证 macOS provider 的归一化结果确实进入详情页。
    nonisolated private static let darwinPlatformProfileOutput = """
    __CONN_UNAME__
    Darwin
    __CONN_RELEASE__
    25.0.0
    __CONN_ARCH__
    arm64
    __CONN_SHELL__
    /bin/zsh
    __CONN_END__
    """

    /// 包含 APFS 系统/数据卷、VPN 虚拟接口和 ioreg 父子重复节点的真实形态夹具。
    nonisolated private static let darwinMetricOutput = """
    __CONN_DARWIN_TOP__
    CPU usage: 12.5% user, 8.0% sys, 79.5% idle
    __CONN_DARWIN_CORES__
    10
    __CONN_DARWIN_MEMSIZE__
    17179869184
    __CONN_DARWIN_VMSTAT__
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages free: 10000.
    Pages active: 450000.
    Pages inactive: 200000.
    Pages speculative: 10000.
    Pages wired down: 180000.
    Pages purgeable: 5000.
    Pages occupied by compressor: 150000.
    __CONN_DARWIN_SWAP__
    total = 4096.00M  used = 512.00M  free = 3584.00M
    __CONN_DARWIN_LOAD__
    12:00  up 10 days, 2 users, load averages: 1.25 1.10 0.95
    __CONN_DARWIN_DISK__
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk3s1s1 500000000 12000000 450000000 11% /
    /dev/disk3s5 500000000 350000000 100000000 78% /System/Volumes/Data
    __CONN_DARWIN_NET__
    Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
    en1 1500 <Link#18> 20:a5:cb:ce:f9:6c 1000 0 5000000 900 0 3000000 0
    utun0 1380 <Link#20> aa:bb:cc:dd:ee:00 1000 0 9000000 900 0 7000000 0
    lo0 16384 <Link#1> 00:00:00:00:00:00 100 0 100000 100 0 100000 0
    __CONN_DARWIN_PRIMARY_INTERFACE__
    en1
    __CONN_DARWIN_IOREG__
      |   "Statistics" = {"Bytes (Read)"=104857600,"Bytes (Write)"=52428800}
          | |   "Statistics" = {"Bytes (Read)"=104857600,"Bytes (Write)"=52428800}
    __CONN_DARWIN_UPTIME__
    864000
    __CONN_DARWIN_IFCONFIG__
    en1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        inet 192.168.8.188 netmask 0xfffffc00 broadcast 192.168.11.255
    __CONN_DARWIN_TCP__
        120 connection requests
        80 connection accepts
        5 bad connection attempts
        1000 packets sent
        20 data packets (24000 bytes) retransmitted
    __CONN_DARWIN_OS__
    ProductName: macOS
    ProductVersion: 26.0
    BuildVersion: 25A123
    __CONN_DARWIN_CPUINFO__
    Apple M2 Pro
    __CONN_DARWIN_END__
    """

    /// 写入演示主机与分组（含一台故障机，覆盖生产/测试/家用三组与多分组归属）。
    ///
    /// 必须一并种分组：否则服务器页的分组筛选条在 `CONN_DEMO` 截图与冒烟模式下
    /// 完全不渲染，新功能不可见。
    static func seedHosts(into store: HostStore, groups groupStore: HostGroupStore) throws {
        let prod = HostGroup(name: L("生产"), sortOrder: 0)
        let staging = HostGroup(name: L("测试"), sortOrder: 1)
        let home = HostGroup(name: L("家用"), sortOrder: 2)
        for group in [prod, staging, home] {
            try groupStore.save(group)
        }

        let hosts = [
            Host(name: "web-01", address: "10.20.0.11", username: "root",
                 groupIDs: [prod.id], tags: ["prod", "web"]),
            Host(name: "api-02", address: "10.20.0.12", username: "deploy",
                 groupIDs: [prod.id], tags: ["prod", "api"]),
            Host(name: "db-01", address: faultHostAddress, username: "root",
                 groupIDs: [prod.id], tags: ["prod", "db"]),
            Host(name: "cache-01", address: "10.20.0.21", username: "deploy",
                 groupIDs: [staging.id], tags: ["staging"]),
            // 同时属于两个分组，用来验证多分组归属。
            Host(name: "worker-01", address: "10.20.0.31", username: "root",
                 groupIDs: [staging.id, prod.id], tags: ["staging", "batch"]),
            Host(name: "nas-01", address: "192.168.1.10", username: "admin",
                 groupIDs: [home.id], tags: ["home"])
        ]
        for host in hosts {
            try store.save(host)
        }
    }
}
#endif
