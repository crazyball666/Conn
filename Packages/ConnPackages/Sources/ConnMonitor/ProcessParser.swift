import Foundation

/// 进程列表解析：GNU `ps` 优先，回退 BusyBox `top`（跨发行版兼容，方案 §4.3）。
enum ProcessParser {
    /// - Parameters:
    ///   - psSection: `ps -eo pid,ppid,user,pcpu,pmem,rss,nlwp,stat,etimes,args` 输出（GNU）。
    ///   - topSection: `top -bn1` 的输出（BusyBox/Alpine 回退）。
    static func parse(psSection: String, topSection: String) -> [RemoteProcess] {
        let fromPS = parseGNUps(psSection)
        return fromPS.isEmpty ? parseBusyBoxTop(topSection) : fromPS
    }

    /// GNU `ps` 输出。列：PID PPID USER %CPU %MEM RSS NLWP STAT ELAPSED COMMAND(args)。
    /// 首行是表头（PID 非数字，guard 自然跳过）。args 为完整命令行、含空格，取剩余全部列。
    static func parseGNUps(_ section: String) -> [RemoteProcess] {
        var result: [RemoteProcess] = []
        for line in section.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 10,
                  let pid = Int32(cols[0]),
                  let cpu = Double(cols[3]),
                  let mem = Double(cols[4]) else { continue } // 表头 / 短行在此被跳过
            let args = cols[9...].joined(separator: " ")
            result.append(RemoteProcess(
                pid: pid,
                command: displayName(fromArgs: args),
                cpu: cpu,
                mem: mem,
                ppid: Int32(cols[1]),
                user: String(cols[2]),
                fullCommand: args,
                memBytes: Int64(cols[5]).map { $0 * 1024 }, // rss(KB) → 字节
                threads: Int(cols[6]),
                state: String(cols[7]),
                elapsedSeconds: Int64(cols[8])
            ))
        }
        return result
    }

    /// BusyBox `top -bn1` 输出。定位以 `PID` 开头的表头，其后为数据行。
    /// 列：PID PPID USER STAT VSZ %VSZ %CPU COMMAND。用 %VSZ 作内存占比近似；
    /// 无 RSS/线程/运行时长（相应字段留 nil）。
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
            result.append(RemoteProcess(
                pid: pid, command: command, cpu: cpu, mem: mem,
                ppid: Int32(cols[1]), user: String(cols[2]),
                fullCommand: command, state: String(cols[3])
            ))
        }
        return result
    }

    /// 从完整命令行取展示短名：首段的 basename，去尾随冒号；内核线程 `[…]` 原样保留。
    private static func displayName(fromArgs args: String) -> String {
        guard let first = args.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return args }
        var token = String(first)
        if token.hasPrefix("[") { return token } // 内核线程 [kworker/…] 原样
        if let slash = token.lastIndex(of: "/") { token = String(token[token.index(after: slash)...]) }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return token.isEmpty ? String(first) : token
    }

    /// 去掉尾部 `%` 后转数字，如 `12%` → 12。
    private static func percent(_ token: Substring) -> Double {
        Double(token.replacingOccurrences(of: "%", with: "")) ?? 0
    }
}
