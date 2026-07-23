import Foundation

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
        let total = values.reduce(0, +)
        let idle = values[3] + values[4] // idle + iowait
        return CPUJiffies(total: total, idle: idle)
    }

    /// `/proc/meminfo` → 内存使用率 0–100。
    ///
    /// 优先 `MemAvailable`（内核 3.14+ 的权威可用内存）；缺失时回退
    /// `MemFree + Buffers + Cached`。
    static func parseMemPercent(_ section: String) -> Double? {
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
        guard let total = values["MemTotal"], total > 0 else { return nil }
        let available: Double
        if let memAvailable = values["MemAvailable"] {
            available = memAvailable
        } else {
            available = (values["MemFree"] ?? 0) + (values["Buffers"] ?? 0) + (values["Cached"] ?? 0)
        }
        let used = max(0, total - available)
        return min(100, used / total * 100)
    }

    /// `/proc/loadavg` → 1 分钟平均负载。
    static func parseLoad1(_ section: String) -> Double? {
        section
            .split(separator: "\n").first?
            .split(separator: " ").first
            .flatMap { Double($0) }
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

    /// `/proc/uptime` → 开机秒数（首个数字）。
    static func parseUptime(_ section: String) -> Double? {
        section
            .split(separator: "\n").first?
            .split(separator: " ").first
            .flatMap { Double($0) }
    }
}
