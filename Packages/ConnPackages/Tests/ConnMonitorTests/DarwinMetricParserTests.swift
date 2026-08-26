import ConnKit
import Foundation
import Testing
@testable import ConnMonitor

@Suite("Darwin metric parser")
struct DarwinMetricParserTests {
    private let output = """
    __CONN_DARWIN_TOP__
    CPU usage: 12.5% user, 8.0% sys, 79.5% idle
    __CONN_DARWIN_CORES__
    8
    __CONN_DARWIN_MEMSIZE__
    17179869184
    __CONN_DARWIN_VMSTAT__
    Mach Virtual Memory Statistics: (page size of 4096 bytes)
    Pages free:                              100000.
    Pages active:                           2500000.
    Pages inactive:                          300000.
    Pages speculative:                        10000.
    Pages wired down:                        800000.
    Pages purgeable:                          20000.
    Pages occupied by compressor:             300000.
    __CONN_DARWIN_SWAP__
    total = 2048.00M  used = 512.00M  free = 1536.00M
    __CONN_DARWIN_LOAD__
     9:41  up 1 day,  2:03, 3 users, load averages: 1.25 1.10 0.95
    __CONN_DARWIN_DISK__
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk3s1s1 500000000 12000000 100000000 11% /
    /dev/disk3s5 500000000 350000000 100000000 78% /System/Volumes/Data
    __CONN_DARWIN_NET__
    Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
    en0 1500 <Link#4> aa:bb:cc:dd:ee:ff 1000 0 5000000 900 0 3000000 0
    en0 1500 192.168.1 192.168.1.20 1000 - 5000000 900 - 3000000 -
    utun0 1380 <Link#20> aa:bb:cc:dd:ee:00 1000 0 9000000 900 0 7000000 0
    lo0 16384 <Link#1> 00:00:00:00:00:00 100 0 100000 100 0 100000 0
    __CONN_DARWIN_PRIMARY_INTERFACE__
    en0
    __CONN_DARWIN_IFCONFIG__
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
    lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        inet 127.0.0.1 netmask 0xff000000
    __CONN_DARWIN_TCP__
        120 connection requests
        80 connection accepts
        5 bad connection attempts
        1000 packets sent
        20 data packets (24000 bytes) retransmitted
    __CONN_DARWIN_IOREG__
      |   "Statistics" = {"Bytes (Read)"=104857600,"Bytes (Write)"=52428800}
          | |   "Statistics" = {"Bytes (Read)"=104857600,"Bytes (Write)"=52428800}
      |   "Statistics" = {"Bytes (Read)"=1024,"Bytes (Write)"=2048}
          |   "Statistics" = {"Bytes (Read)"=1024,"Bytes (Write)"=2048}
    __CONN_DARWIN_UPTIME__
    123456
    __CONN_DARWIN_OS__
    ProductName:		macOS
    ProductVersion:	15.1
    BuildVersion:		24B83
    __CONN_DARWIN_CPUINFO__
    Apple M2 Max
    __CONN_DARWIN_END__
    """

    @Test("CPU、负载与系统资料")
    func cpuAndSystem() {
        let parsed = DarwinMetricParser.parse(output)

        #expect(parsed.cpuInstantPercent == 20.5)
        #expect(parsed.cpuBreakdownInstant?.user == 12.5)
        #expect(parsed.cpuBreakdownInstant?.system == 8)
        #expect(parsed.cpuBreakdownInstant?.idle == 79.5)
        #expect(parsed.cpuCores == 8)
        #expect(parsed.cpuModel == "Apple M2 Max")
        #expect(parsed.osName == "macOS 15.1 (24B83)")
        #expect(parsed.load1 == 1.25)
        #expect(parsed.load5 == 1.10)
        #expect(parsed.load15 == 0.95)
        #expect(parsed.uptimeSeconds == 123_456)
    }

    @Test("内存、Swap 与磁盘")
    func memoryAndDisk() {
        let parsed = DarwinMetricParser.parse(output)
        let availablePages = Double(100_000 + 300_000 + 10_000)
        let availableBytes = availablePages * 4096

        #expect(parsed.memTotalBytes == 17_179_869_184)
        #expect(parsed.memUsedBytes == 17_179_869_184 - availableBytes)
        #expect(parsed.memFree == Double(100_000 * 4096))
        #expect(parsed.memBuffersCache == Double((300_000 + 10_000) * 4096))
        #expect(parsed.swapTotalBytes == Double(2048 * 1024 * 1024))
        #expect(parsed.swapUsedBytes == Double(512 * 1024 * 1024))
        // APFS 系统卷是只读快照；主机占用应按容器总量减可用量计算，不能取 `/` 的 Used。
        #expect(parsed.diskUsedBytes == Double(400_000_000 * 1024))
        #expect(parsed.diskTotalBytes == Double(500_000_000 * 1024))
    }

    @Test("网络、TCP 与磁盘 IO")
    func networkAndIO() {
        let parsed = DarwinMetricParser.parse(output)

        #expect(parsed.netRxBytes == 5_000_000)
        #expect(parsed.netTxBytes == 3_000_000)
        #expect(parsed.netCounterIdentity == "en0")
        #expect(parsed.netInterfaces == [
            RawInterface(name: "en0", rx: 5_000_000, tx: 3_000_000),
            RawInterface(name: "lo0", rx: 100_000, tx: 100_000),
            RawInterface(name: "utun0", rx: 9_000_000, tx: 7_000_000),
        ])
        #expect(parsed.interfaceIPs["en0"] == "192.168.1.20")
        #expect(parsed.interfaceIPs["lo0"] == "127.0.0.1")
        #expect(parsed.tcp?.activeOpens == 120)
        #expect(parsed.tcp?.passiveOpens == 80)
        #expect(parsed.tcp?.attemptFails == 5)
        #expect(parsed.tcp?.retransRate == 2)
        // ioreg 子节点重复报告父设备累计值；只汇总最浅层设备节点。
        #expect(parsed.ioReadBytes == 104_858_624)
        #expect(parsed.ioWriteBytes == 52_430_848)
    }

    @Test("现代 macOS 缺少可选逐核采样时不误报核心指标降级")
    func optionalPerCoreDoesNotDegradeCoreMetrics() {
        let parsed = DarwinMetricParser.parse(output)

        #expect(parsed.cpuPerCore.isEmpty)
        #expect(parsed.capabilityState == .supported)
    }

    @Test("采集命令固定 C locale，避免本地化输出破坏解析")
    func commandUsesStableLocale() {
        #expect(DarwinCollectionScript.command().hasPrefix("export LC_ALL=C LANG=C; "))
        #expect(DarwinCollectionScript.command().contains("route -n get default"))
    }

    #if os(macOS)
    @Test("运行时长提取 sec 字段而不是 usec 字段")
    func uptimeCommandExtractsBootEpoch() throws {
        let command = DarwinCollectionScript.uptimeCommand(
            bootTimeSource: "printf '%s\\n' '{ sec = 1720000000, usec = 773848 } Thu Jul  4 09:46:40 2024'",
            nowSource: "printf '%s\\n' 1720123456"
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let result = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0)
        #expect(result == "123456")
        #expect(result != "1719349608")
    }
    #endif
}
