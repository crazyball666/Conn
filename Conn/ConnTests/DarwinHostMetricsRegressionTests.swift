import ConnKit
import ConnMonitor
import Testing

@Suite("Darwin host metrics regression")
struct DarwinHostMetricsRegressionTests {
    @Test("APFS、VPN 接口与 ioreg 层级按 macOS 语义归一化")
    func normalizesModernMacMetrics() {
        let parsed = DarwinMetricParser.parse(Self.output)

        #expect(parsed.diskUsedBytes == Double(400_000_000 * 1024))
        #expect(parsed.diskTotalBytes == Double(500_000_000 * 1024))
        #expect(parsed.netRxBytes == 5_000_000)
        #expect(parsed.netTxBytes == 3_000_000)
        #expect(parsed.netCounterIdentity == "en0")
        #expect(parsed.ioReadBytes == 104_858_624)
        #expect(parsed.ioWriteBytes == 52_430_848)
        #expect(parsed.memBuffersCache == Double(310_000 * 4096))
        #expect(parsed.memUsedBytes == 17_179_869_184 - Double(410_000 * 4096))
        #expect(parsed.cpuPerCore.isEmpty)
        #expect(parsed.capabilityState == .supported)
    }

    @Test("修正只进入 Darwin provider")
    func changeIsDarwinScoped() throws {
        let darwin = try #require(MetricsProviderRegistry.provider(for: .macOS))
        let linux = try #require(MetricsProviderRegistry.provider(for: .linux))

        #expect(darwin.command(includeExtended: true).contains("route -n get default"))
        #expect(!darwin.command(includeExtended: true).contains("/proc/"))
        #expect(linux.command(includeExtended: true).contains("/proc/stat"))
        #expect(!linux.command(includeExtended: true).contains("route -n get default"))
    }

    private static let output = """
    __CONN_DARWIN_TOP__
    CPU usage: 12.5% user, 8.0% sys, 79.5% idle
    __CONN_DARWIN_CORES__
    10
    __CONN_DARWIN_MEMSIZE__
    17179869184
    __CONN_DARWIN_VMSTAT__
    Mach Virtual Memory Statistics: (page size of 4096 bytes)
    Pages free: 100000.
    Pages inactive: 300000.
    Pages speculative: 10000.
    Pages purgeable: 20000.
    __CONN_DARWIN_DISK__
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk3s1s1 500000000 12000000 450000000 11% /
    /dev/disk3s5 500000000 350000000 100000000 78% /System/Volumes/Data
    __CONN_DARWIN_NET__
    Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
    en0 1500 <Link#4> aa:bb:cc:dd:ee:ff 1000 0 5000000 900 0 3000000 0
    utun0 1380 <Link#20> aa:bb:cc:dd:ee:00 1000 0 9000000 900 0 7000000 0
    __CONN_DARWIN_PRIMARY_INTERFACE__
    en0
    __CONN_DARWIN_IOREG__
      |   "Statistics" = {"Bytes (Read)"=104857600,"Bytes (Write)"=52428800}
          | |   "Statistics" = {"Bytes (Read)"=104857600,"Bytes (Write)"=52428800}
      |   "Statistics" = {"Bytes (Read)"=1024,"Bytes (Write)"=2048}
          |   "Statistics" = {"Bytes (Read)"=1024,"Bytes (Write)"=2048}
    __CONN_DARWIN_UPTIME__
    123456
    __CONN_DARWIN_END__
    """
}
