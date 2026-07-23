import Foundation

/// 进程列表解析：GNU `ps` 优先，回退 BusyBox `top`（跨发行版兼容，方案 §4.3）。
enum ProcessParser {
    /// - Parameters:
    ///   - psSection: `ps -eo pid,pcpu,pmem,comm --sort=-pcpu` 的输出（GNU）。
    ///   - topSection: `top -bn1` 的输出（BusyBox/Alpine 回退）。
    static func parse(psSection: String, topSection: String) -> [RemoteProcess] {
        let fromPS = parseGNUps(psSection)
        return fromPS.isEmpty ? parseBusyBoxTop(topSection) : fromPS
    }

    /// GNU `ps` 输出。列：PID %CPU %MEM COMMAND。首行是表头。
    static func parseGNUps(_ section: String) -> [RemoteProcess] {
        var result: [RemoteProcess] = []
        for line in section.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 4,
                  let pid = Int32(cols[0]),
                  let cpu = Double(cols[1]),
                  let mem = Double(cols[2]) else { continue } // 表头行在此被跳过
            let command = cols[3...].joined(separator: " ")
            result.append(RemoteProcess(pid: pid, command: command, cpu: cpu, mem: mem))
        }
        return result
    }

    /// BusyBox `top -bn1` 输出。定位以 `PID` 开头的表头，其后为数据行。
    /// 列：PID PPID USER STAT VSZ %VSZ %CPU COMMAND。用 %VSZ 作内存占比近似。
    static func parseBusyBoxTop(_ section: String) -> [RemoteProcess] {
        let lines = section.split(separator: "\n", omittingEmptySubsequences: false)
        guard let headerIndex = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("PID") && trimmed.contains("COMMAND")
        }) else { return [] }

        var result: [RemoteProcess] = []
        for line in lines[(headerIndex + 1)...] {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 8, let pid = Int32(cols[0]) else { continue }
            let mem = percent(cols[5])
            let cpu = percent(cols[6])
            let command = cols[7...].joined(separator: " ")
            result.append(RemoteProcess(pid: pid, command: command, cpu: cpu, mem: mem))
        }
        return result
    }

    /// 去掉尾部 `%` 后转数字，如 `12%` → 12。
    private static func percent(_ token: Substring) -> Double {
        Double(token.replacingOccurrences(of: "%", with: "")) ?? 0
    }
}
