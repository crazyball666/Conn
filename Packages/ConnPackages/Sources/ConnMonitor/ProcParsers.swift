import Foundation

/// 1 / 5 / 15 分钟平均负载。
struct LoadAverages: Sendable, Equatable {
    let one: Double
    let five: Double
    let fifteen: Double
}

/// 内存明细（字节）：总量 / 已用 / 缓冲缓存 / 空闲，以及 Swap 总量 / 已用。
struct MemoryBreakdown: Sendable, Equatable {
    let total: Double
    let used: Double
    let buffersCache: Double
    let free: Double
    let swapTotal: Double?
    let swapUsed: Double?
}

/// `/proc` 与 `df` 各段的解析。全部纯函数。
enum ProcParsers {
    /// `/proc/stat` 首行 → CPU jiffies 快照。
    ///
    /// 首行形如 `cpu  user nice system idle iowait irq softirq steal ...`。
    static func parseStat(_ section: String) -> CPUJiffies? {
        guard let line = section
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("cpu ") || $0.hasPrefix("cpu\t") })
        else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst()
        let values = fields.compactMap { Double($0) }
        // 至少要有 user…idle…iowait 前 5 项才可信
        guard values.count >= 5 else { return nil }
        // #17：只累加前 8 项 user..steal。guest/guest_nice(第 9/10 项)已并入 user/nice，
        // 全量求和会在虚拟化宿主上重复计入 → CPU% 偏高。
        let total = values.prefix(8).reduce(0, +)
        let idle = values[3] + values[4] // idle + iowait
        return CPUJiffies(total: total, idle: idle)
    }

    /// `/proc/stat` 汇总行 → 各时间片累计（供 CPU 各类占比差分）。
    /// 行形如 `cpu user nice system idle iowait irq softirq steal …`。
    static func parseStatTimes(_ section: String) -> CPUTimes? {
        guard let line = section
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("cpu ") || $0.hasPrefix("cpu\t") })
        else { return nil }
        let values = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst()
            .compactMap { Double($0) }
        guard values.count >= 8 else { return nil }
        return CPUTimes(
            user: values[0], nice: values[1], system: values[2], idle: values[3],
            iowait: values[4], irq: values[5], softirq: values[6], steal: values[7]
        )
    }

    /// `/proc/stat` → 逻辑核心数（`cpu0`、`cpu1`… 每核一行；`cpu ` 汇总行不计）。
    static func parseCoreCount(_ section: String) -> Int? {
        let count = parsePerCore(section).count
        return count > 0 ? count : nil
    }

    /// `/proc/stat` 每个 `cpuN` 行 → 各逻辑核 jiffies 快照（顺序即核序）。
    /// 各核利用率由 `MetricCollector` 跨样本逐核差分算出。
    static func parsePerCore(_ section: String) -> [CPUJiffies] {
        var cores: [CPUJiffies] = []
        for line in section.split(separator: "\n")
        where line.hasPrefix("cpu") && (line.dropFirst(3).first?.isNumber ?? false) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst()
            let values = fields.compactMap { Double($0) }
            guard values.count >= 5 else { continue }
            let total = values.prefix(8).reduce(0, +)
            let idle = values[3] + values[4]
            cores.append(CPUJiffies(total: total, idle: idle))
        }
        return cores
    }

    /// `/proc/meminfo` → （总字节, 已用字节）。
    ///
    /// 优先 `MemAvailable`（内核 3.14+ 的权威可用内存）；缺失时回退
    /// `MemFree + Buffers + Cached`。字段单位 kB → ×1024 转字节。
    static func parseMemInfo(_ section: String) -> (totalBytes: Double, usedBytes: Double)? {
        var values: [String: Double] = [:]
        for line in section.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            // 值形如 "  16324884 kB"，取首个数字
            if let number = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" })
                .compactMap({ Double($0) }).first {
                values[key] = number
            }
        }
        guard let totalKB = values["MemTotal"], totalKB > 0 else { return nil }
        let availableKB: Double
        if let memAvailable = values["MemAvailable"] {
            availableKB = memAvailable
        } else {
            availableKB = (values["MemFree"] ?? 0) + (values["Buffers"] ?? 0) + (values["Cached"] ?? 0)
        }
        let usedKB = max(0, totalKB - availableKB)
        return (totalKB * 1024, usedKB * 1024)
    }

    /// `/proc/meminfo` → 内存使用率 0–100。
    static func parseMemPercent(_ section: String) -> Double? {
        guard let info = parseMemInfo(section), info.totalBytes > 0 else { return nil }
        return min(100, info.usedBytes / info.totalBytes * 100)
    }

    /// `/proc/diskstats` → 累计读/写字节（整盘扇区求和 ×512）。
    ///
    /// 扇区在 `/proc/diskstats` 里固定按 512 字节计（与物理扇区大小无关）。
    /// 只累加整盘、排除分区（避免与整盘重复）与 loop/ram/dm 等虚拟设备。
    /// 列：major minor name reads reads_merged **sectors_read** … writes writes_merged **sectors_written** …
    static func parseDiskstats(_ section: String) -> (read: Int64, write: Int64)? {
        var readSectors: Int64 = 0
        var writeSectors: Int64 = 0
        var matched = false
        for line in section.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 10, isWholeDisk(String(cols[2])),
                  let readSec = Int64(cols[5]), let writeSec = Int64(cols[9]) else { continue }
            readSectors += readSec
            writeSectors += writeSec
            matched = true
        }
        return matched ? (readSectors * 512, writeSectors * 512) : nil
    }

    /// 判断是否整盘（用于 diskstats 汇总，排除分区/虚拟设备防重复计数）。
    private static func isWholeDisk(_ name: String) -> Bool {
        for prefix in ["loop", "ram", "dm-", "sr", "fd", "zram"] where name.hasPrefix(prefix) {
            return false
        }
        // nvme0n1 / mmcblk0 为整盘,其分区名含 "p<n>"（nvme0n1p1、mmcblk0p1）。
        if name.hasPrefix("nvme") || name.hasPrefix("mmcblk") {
            return !name.contains("p")
        }
        // sd/vd/xvd/hd 等：整盘无尾随数字,分区有（sda vs sda1）。
        if let last = name.last { return !last.isNumber }
        return false
    }

    /// `/proc/loadavg` → 1 分钟平均负载。
    static func parseLoad1(_ section: String) -> Double? {
        parseLoadAvg(section)?.one
    }

    /// `/proc/loadavg` → 1 / 5 / 15 分钟平均负载。
    static func parseLoadAvg(_ section: String) -> LoadAverages? {
        let fields = section
            .split(separator: "\n").first?
            .split(separator: " ")
            .compactMap { Double($0) } ?? []
        guard fields.count >= 3 else { return nil }
        return LoadAverages(one: fields[0], five: fields[1], fifteen: fields[2])
    }

    /// `/etc/os-release` → 发行版友好名（`PRETTY_NAME`）。
    static func parseOSName(_ section: String) -> String? {
        for line in section.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            let value = line.dropFirst("PRETTY_NAME=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `grep model name /proc/cpuinfo` → CPU 型号（冒号后部分）。
    static func parseCPUModel(_ section: String) -> String? {
        guard let line = section.split(separator: "\n").first,
              let colon = line.firstIndex(of: ":") else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// `/proc/meminfo` → 四分（已用 / 缓冲缓存 / 空闲 / 总计）字节，供内存明细。
    ///
    /// 已用 = 总 − 空闲 − 缓冲缓存（`free` 口径，剔除可回收缓存）；三者之和 ≈ 总量。
    static func parseMemBreakdown(_ section: String) -> MemoryBreakdown? {
        var values: [String: Double] = [:]
        for line in section.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if let number = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" })
                .compactMap({ Double($0) }).first {
                values[key] = number * 1024 // kB → 字节
            }
        }
        guard let total = values["MemTotal"], total > 0 else { return nil }
        let free = values["MemFree"] ?? 0
        let buffersCache = (values["Buffers"] ?? 0) + (values["Cached"] ?? 0)
        let used = max(0, total - free - buffersCache)
        let swapTotal = values["SwapTotal"]
        let swapFree = values["SwapFree"]
        let swapUsed: Double?
        if let swapTotal, let swapFree {
            swapUsed = max(0, swapTotal - swapFree)
        } else {
            swapUsed = nil
        }
        return MemoryBreakdown(
            total: total, used: used, buffersCache: buffersCache, free: free,
            swapTotal: swapTotal, swapUsed: swapUsed
        )
    }

    /// `df -P -k` → 根挂载点（`/`）的已用/总字节数。
    ///
    /// POSIX `-P` 保证每个文件系统一行不折行。列：Filesystem 1024-blocks Used
    /// Available Capacity Mounted-on。找 `/`，找不到则取容量最大的。
    private struct DiskEntry {
        let mount: String
        let used: Double
        let total: Double
    }

    static func parseDisk(_ section: String) -> (used: Double, total: Double)? {
        var candidates: [DiskEntry] = []
        for line in section.split(separator: "\n").dropFirst() { // 跳表头
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 6,
                  let blocks = Double(cols[cols.count - 5]),
                  let used = Double(cols[cols.count - 4]) else { continue }
            let mount = String(cols[cols.count - 1])
            candidates.append(DiskEntry(mount: mount, used: used * 1024, total: blocks * 1024))
        }
        if let root = candidates.first(where: { $0.mount == "/" }) {
            return (root.used, root.total)
        }
        guard let largest = candidates.max(by: { $0.total < $1.total }) else { return nil }
        return (largest.used, largest.total)
    }

    /// `/proc/net/dev` → 累计收/发字节数（排除 lo）。速率由相邻样本差分得出。
    static func parseNet(_ section: String) -> (rx: Int64, tx: Int64)? {
        var rxSum: Int64 = 0
        var txSum: Int64 = 0
        var matched = false
        for line in section.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count == 2 else { continue } // 跳两行表头
            let iface = parts[0].trimmingCharacters(in: .whitespaces)
            guard iface != "lo", !iface.isEmpty else { continue }
            let stats = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard stats.count >= 9,
                  let rx = Int64(stats[0]), let tx = Int64(stats[8]) else { continue }
            rxSum += rx
            txSum += tx
            matched = true
        }
        return matched ? (rxSum, txSum) : nil
    }

    /// `/proc/net/dev` → 各网卡累计收/发字节（保留 lo，含虚拟网卡）。速率由差分得出。
    static func parseNetInterfaces(_ section: String) -> [RawInterface] {
        var result: [RawInterface] = []
        for line in section.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let stats = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard stats.count >= 9, let rx = Int64(stats[0]), let tx = Int64(stats[8]) else { continue }
            result.append(RawInterface(name: name, rx: rx, tx: tx))
        }
        return result
    }

    /// `/proc/net/snmp` 的 Tcp 行 → TCP 统计（按表头列名定位，跨内核稳健）。
    static func parseTCPStats(_ section: String) -> TCPStats? {
        let tcpLines = section.split(separator: "\n").filter { $0.hasPrefix("Tcp:") }
        guard tcpLines.count >= 2 else { return nil }
        let headers = tcpLines[0].split(separator: " ").map(String.init)
        let values = tcpLines[1].split(separator: " ").map(String.init)
        func field(_ key: String) -> Int64? {
            guard let index = headers.firstIndex(of: key), index < values.count else { return nil }
            return Int64(values[index])
        }
        guard let active = field("ActiveOpens"), let passive = field("PassiveOpens"),
              let fails = field("AttemptFails"), let out = field("OutSegs"),
              let retrans = field("RetransSegs")
        else { return nil }
        let rate = out > 0 ? Double(retrans) / Double(out) * 100 : 0
        return TCPStats(retransRate: rate, activeOpens: active, passiveOpens: passive, attemptFails: fails)
    }

    /// `ip -o -4 addr show` → 网卡名 → IPv4。行形如 `2: eth0    inet 1.2.3.4/24 …`。
    static func parseIPs(_ section: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in section.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, let inetIndex = fields.firstIndex(of: "inet"),
                  inetIndex + 1 < fields.count else { continue }
            let ip = fields[inetIndex + 1].split(separator: "/").first.map(String.init)
            result[fields[1]] = ip ?? fields[inetIndex + 1]
        }
        return result
    }

    /// `/proc/uptime` → 开机秒数（首个数字）。
    static func parseUptime(_ section: String) -> Double? {
        section
            .split(separator: "\n").first?
            .split(separator: " ").first
            .flatMap { Double($0) }
    }
}
