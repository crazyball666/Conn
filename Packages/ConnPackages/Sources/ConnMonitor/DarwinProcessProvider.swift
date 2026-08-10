import ConnKit
import Foundation

/// macOS 使用 BSD `ps`；不依赖 GNU `--sort`、`nlwp` 或 BusyBox `top`。
public struct DarwinProcessProvider: ProcessProvider {
    private enum Sentinel {
        static let process = "__CONN_DARWIN_PROCESS_PS__"
        static let end = "__CONN_DARWIN_PROCESS_END__"
    }

    public let platform = RemotePlatformKind.macOS
    public let capabilityState = CapabilityState.degraded(issues: [
        CapabilityIssue(
            code: .partialData,
            detail: "BSD ps does not expose a stable process thread-count field",
            fields: ["threadCount"]
        ),
    ])

    public init() {}

    public var command: String {
        [
            "export LC_ALL=C LANG=C",
            "echo \(Sentinel.process)",
            "ps -axo pid=PID,ppid=PPID,user=USER,%cpu=%CPU,%mem=%MEM,rss=RSS,state=STAT,etime=ELAPSED,command=COMMAND",
            "conn_process_status=$?",
            "echo \(Sentinel.end)",
            "exit $conn_process_status",
        ].joined(separator: "; ")
    }

    public func parse(_ output: String) -> [RemoteProcess] {
        let section = processSection(output)
        var processes: [RemoteProcess] = []
        for line in section.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 9,
                  let pid = Int32(columns[0]),
                  let cpu = Double(columns[3]),
                  let memory = Double(columns[4]),
                  let rss = Int64(columns[5]),
                  let elapsed = Self.elapsedSeconds(String(columns[7])) else { continue }
            let fullCommand = columns[8...].joined(separator: " ")
            processes.append(RemoteProcess(
                pid: pid,
                command: ProcessParser.displayName(fromArgs: fullCommand),
                cpu: cpu,
                mem: memory,
                ppid: Int32(columns[1]),
                user: String(columns[2]),
                fullCommand: fullCommand,
                memBytes: rss * 1024,
                threads: nil,
                state: String(columns[6]),
                elapsedSeconds: elapsed
            ))
        }
        return Array(processes.sorted { $0.cpu > $1.cpu }.prefix(500))
    }

    private func processSection(_ output: String) -> String {
        guard let start = output.range(of: Sentinel.process) else { return "" }
        let tail = output[start.upperBound...]
        guard let end = tail.range(of: Sentinel.end) else { return String(tail) }
        return String(tail[..<end.lowerBound])
    }

    /// BSD `etime` 格式为 `[[dd-]hh:]mm:ss`。
    static func elapsedSeconds(_ value: String) -> Int64? {
        let dayAndTime = value.split(separator: "-", maxSplits: 1)
        let days: Int64
        let time: Substring
        if dayAndTime.count == 2 {
            guard let parsedDays = Int64(dayAndTime[0]) else { return nil }
            days = parsedDays
            time = dayAndTime[1]
        } else {
            days = 0
            time = dayAndTime[0]
        }
        let components = time.split(separator: ":").compactMap { Int64($0) }
        guard components.count == 2 || components.count == 3 else { return nil }
        let hours = components.count == 3 ? components[0] : 0
        let minutes = components.count == 3 ? components[1] : components[0]
        let seconds = components.count == 3 ? components[2] : components[1]
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }
}
