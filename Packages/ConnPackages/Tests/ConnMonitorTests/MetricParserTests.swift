import Foundation
import Testing
@testable import ConnMonitor

/// GNU/BusyBox 两套样本 fixture 的解析覆盖（技术方案 §4.3 验收项）。
struct MetricParserTests {
    // MARK: - GNU（Ubuntu/Debian/CentOS 典型）

    private let gnuOutput = """
    __CONN_STAT__
    cpu  100 10 50 1000 20 0 5 0 0 0
    cpu0 50 5 25 500 10 0 2 0 0 0
    __CONN_MEM__
    MemTotal:        4096000 kB
    MemFree:          512000 kB
    MemAvailable:    2048000 kB
    Buffers:          100000 kB
    Cached:           800000 kB
    __CONN_LOAD__
    0.42 0.35 0.30 2/345 6789
    __CONN_DISK__
    Filesystem     1024-blocks     Used Available Capacity Mounted on
    /dev/vda1         41152000 18000000  21000000      47% /
    tmpfs              2048000        0   2048000       0% /dev/shm
    __CONN_NET__
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo:    1000      10    0    0    0     0          0         0     1000      10    0    0    0     0       0          0
      eth0: 5000000    4000    0    0    0     0          0         0  3000000    3500    0    0    0     0       0          0
    __CONN_IO__
       8       0 sda 1000 0 200000 500 800 0 100000 400 0 300 900
       8       1 sda1 500 0 50000 200 400 0 20000 100 0 100 300
     252       0 dm-0 300 0 10000 100 200 0 5000 50 0 50 150
    __CONN_UPTIME__
    123456.78 987654.32
    __CONN_OS__
    PRETTY_NAME="Ubuntu 24.04.1 LTS"
    ID=ubuntu
    __CONN_CPUINFO__
    model name	: Intel(R) Xeon(R) CPU E5-2698 v4 @ 2.20GHz
    __CONN_PS__
        PID %CPU %MEM COMMAND
          1  0.0  0.1 systemd
        234 12.5  4.2 nginx
        567  8.1  2.0 mysqld
    __CONN_TOP__
    __CONN_END__
    """

    @Test("GNU：CPU jiffies 快照")
    func gnuCPU() {
        let parsed = MetricParser.parse(gnuOutput)
        #expect(parsed.cpu?.total == 1185) // 100+10+50+1000+20+0+5
        #expect(parsed.cpu?.idle == 1020) // idle 1000 + iowait 20
    }

    @Test("GNU：内存使用率用 MemAvailable")
    func gnuMem() {
        let parsed = MetricParser.parse(gnuOutput)
        // used = 4096000 - 2048000 = 2048000 → 50%
        #expect(parsed.memPercent == 50)
    }

    @Test("GNU：负载 / 磁盘 / 网络 / 开机时长")
    func gnuMisc() {
        let parsed = MetricParser.parse(gnuOutput)
        #expect(parsed.load1 == 0.42)
        #expect(parsed.diskUsedBytes == 18_000_000 * 1024)
        #expect(parsed.diskTotalBytes == 41_152_000 * 1024)
        #expect(parsed.netRxBytes == 5_000_000) // 排除 lo
        #expect(parsed.netTxBytes == 3_000_000)
        #expect(parsed.uptimeSeconds == 123_456.78)
    }

    @Test("GNU：核心数 / 内存字节 / 磁盘 IO 总量")
    func gnuExtras() {
        let parsed = MetricParser.parse(gnuOutput)
        #expect(parsed.cpuCores == 1) // 仅 cpu0 一行
        #expect(parsed.memTotalBytes == 4_096_000 * 1024)
        #expect(parsed.memUsedBytes == 2_048_000 * 1024) // total - MemAvailable
        // sda 整盘扇区读/写 ×512；排除分区 sda1 与 dm-0
        #expect(parsed.ioReadBytes == Int64(200_000 * 512))
        #expect(parsed.ioWriteBytes == Int64(100_000 * 512))
    }

    @Test("GNU：负载 1/5/15 · 系统名 · CPU 型号 · 内存明细")
    func gnuBasics() {
        let parsed = MetricParser.parse(gnuOutput)
        #expect(parsed.load1 == 0.42)
        #expect(parsed.load5 == 0.35)
        #expect(parsed.load15 == 0.30)
        #expect(parsed.osName == "Ubuntu 24.04.1 LTS")
        #expect(parsed.cpuModel == "Intel(R) Xeon(R) CPU E5-2698 v4 @ 2.20GHz")
        // 空闲 = MemFree；缓冲缓存 = Buffers + Cached
        #expect(parsed.memFree == 512_000 * 1024)
        #expect(parsed.memBuffersCache == 900_000 * 1024)
    }

    @Test("GNU：进程按 ps 解析")
    func gnuProcesses() {
        let parsed = MetricParser.parse(gnuOutput)
        #expect(parsed.processes.count == 3)
        #expect(parsed.processes.first?.pid == 1)
        #expect(parsed.processes.first?.command == "systemd")
        #expect(parsed.processes[1].cpu == 12.5)
        #expect(parsed.processes[1].command == "nginx")
    }

    // MARK: - BusyBox（Alpine 典型：ps -eo 无输出，回退 top）

    private let busyboxOutput = """
    __CONN_STAT__
    cpu  200 0 100 5000 50 0 10 0
    __CONN_MEM__
    MemTotal:         512000 kB
    MemFree:          128000 kB
    Buffers:           10000 kB
    Cached:            64000 kB
    __CONN_LOAD__
    0.05 0.10 0.08 1/50 999
    __CONN_DISK__
    Filesystem           1024-blocks      Used Available Capacity Mounted on
    overlay                 20480000   5120000  15360000      25% /
    __CONN_NET__
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo:     500       5    0    0    0     0          0         0      500       5    0    0    0     0       0          0
      eth0:  900000     800    0    0    0     0          0         0   700000     600    0    0    0     0       0          0
    __CONN_UPTIME__
    54321.00 65432.10
    __CONN_PS__
    __CONN_TOP__
    Mem: 384000K used, 128000K free, 0K shrd, 10000K buff, 64000K cached
    CPU:   5% usr   2% sys   0% nic  90% idle   0% io   0% irq   1% sirq
    Load average: 0.05 0.10 0.08 1/50 999
      PID  PPID USER     STAT   VSZ %VSZ %CPU COMMAND
        1     0 root     S     2000   1%   3% init
      456     1 root     S     8000   4%  10% nginx
    __CONN_END__
    """

    @Test("BusyBox：内存无 MemAvailable，回退 Free+Buffers+Cached")
    func busyboxMemFallback() {
        let parsed = MetricParser.parse(busyboxOutput)
        // available = 128000 + 10000 + 64000 = 202000; used = 512000-202000 = 310000
        // 310000/512000*100 ≈ 60.546875
        #expect(abs((parsed.memPercent ?? 0) - 60.546875) < 0.0001)
    }

    @Test("BusyBox：进程回退 top 解析")
    func busyboxProcesses() {
        let parsed = MetricParser.parse(busyboxOutput)
        #expect(parsed.processes.count == 2)
        #expect(parsed.processes.first?.pid == 1)
        #expect(parsed.processes.first?.command == "init")
        #expect(parsed.processes.first?.cpu == 3) // %CPU 列
        #expect(parsed.processes.first?.mem == 1) // %VSZ 列作近似
        #expect(parsed.processes[1].command == "nginx")
        #expect(parsed.processes[1].cpu == 10)
    }

    @Test("BusyBox：overlay 作根盘（无 /dev/vda 时取 / 挂载点）")
    func busyboxDisk() {
        let parsed = MetricParser.parse(busyboxOutput)
        #expect(parsed.diskUsedBytes == 5_120_000 * 1024)
        #expect(parsed.diskTotalBytes == 20_480_000 * 1024)
    }

    // MARK: - 缺段容忍

    @Test("空输出不崩、全 nil")
    func emptyOutput() {
        let parsed = MetricParser.parse("")
        #expect(parsed.cpu == nil)
        #expect(parsed.memPercent == nil)
        #expect(parsed.diskPercent == nil)
        #expect(parsed.processes.isEmpty)
    }

    @Test("只有磁盘段、无根挂载点时取容量最大者")
    func diskLargestFallback() {
        let output = """
        __CONN_DISK__
        Filesystem     1024-blocks    Used Available Capacity Mounted on
        tmpfs               100000    1000     99000       1% /run
        /dev/sdb1         50000000 1000000  49000000       2% /data
        __CONN_END__
        """
        let parsed = MetricParser.parse(output)
        #expect(parsed.diskTotalBytes == 50_000_000 * 1024) // /data 最大
    }
}
