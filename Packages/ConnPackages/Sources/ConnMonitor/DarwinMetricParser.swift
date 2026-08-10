import ConnKit
import Foundation

/// macOS 系统命令输出解析器。全部为纯函数，便于用不同 macOS 版本 fixture 验证。
public enum DarwinMetricParser {
    public static func parse(_ output: String) -> ParsedMetrics {
        let sections = splitSections(output)
        func section(_ key: String) -> String { sections[key] ?? "" }

        let cpu = parseCPU(section(DarwinCollectionScript.Sentinel.top))
        let memory = parseMemory(
            total: section(DarwinCollectionScript.Sentinel.memsize),
            vmstat: section(DarwinCollectionScript.Sentinel.vmstat)
        )
        let swap = parseSwap(section(DarwinCollectionScript.Sentinel.swap))
        let load = parseLoad(section(DarwinCollectionScript.Sentinel.load))
        let disk = ProcParsers.parseDisk(section(DarwinCollectionScript.Sentinel.disk))
        let interfaces = parseInterfaces(section(DarwinCollectionScript.Sentinel.net))
        let totals = interfaceTotals(interfaces)
        let io = parseIORegistry(section(DarwinCollectionScript.Sentinel.ioreg))

        var missing: [String] = []
        if cpu == nil { missing.append("cpu") }
        if memory == nil { missing.append("memory") }
        if disk == nil { missing.append("disk") }
        if totals == nil { missing.append("network") }
        missing.append("cpuPerCore")
        let state: CapabilityState = missing.isEmpty ? .supported : .degraded(issues: [
            CapabilityIssue(
                code: .partialData,
                detail: "macOS returned only part of the host metrics",
                fields: missing
            ),
        ])

        return ParsedMetrics(
            cpuInstantPercent: cpu?.usage,
            cpuBreakdownInstant: cpu?.breakdown,
            cpuCores: firstInt(section(DarwinCollectionScript.Sentinel.cores)),
            cpuModel: firstNonemptyLine(section(DarwinCollectionScript.Sentinel.cpuinfo)),
            osName: parseOS(section(DarwinCollectionScript.Sentinel.os)),
            memPercent: memory?.percent,
            memTotalBytes: memory?.total,
            memUsedBytes: memory?.used,
            memBuffersCache: memory?.cache,
            memFree: memory?.free,
            swapTotalBytes: swap?.total,
            swapUsedBytes: swap?.used,
            load1: load?.one,
            load5: load?.five,
            load15: load?.fifteen,
            diskUsedBytes: disk?.used,
            diskTotalBytes: disk?.total,
            netRxBytes: totals?.rx,
            netTxBytes: totals?.tx,
            netInterfaces: interfaces,
            interfaceIPs: parseIPs(section(DarwinCollectionScript.Sentinel.ifconfig)),
            tcp: parseTCP(section(DarwinCollectionScript.Sentinel.tcp)),
            ioReadBytes: io?.read,
            ioWriteBytes: io?.write,
            uptimeSeconds: firstDouble(section(DarwinCollectionScript.Sentinel.uptime)),
            capabilityState: state
        )
    }

    private static func splitSections(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var buffer: [Substring] = []
        func flush() {
            if let current { result[current] = buffer.joined(separator: "\n") }
            buffer.removeAll(keepingCapacity: true)
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if DarwinCollectionScript.Sentinel.all.contains(trimmed) {
                flush()
                current = trimmed
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }

    private static func parseCPU(_ section: String) -> (usage: Double, breakdown: CPUBreakdown)? {
        guard let line = section.split(separator: "\n").first else { return nil }
        func percent(_ label: String) -> Double? {
            for component in line.split(separator: ",") where component.contains(label) {
                let prefix = component.split(separator: "%", maxSplits: 1).first ?? ""
                if let value = prefix.split(whereSeparator: { $0 == " " || $0 == ":" }).last,
                   let number = Double(value) {
                    return number
                }
            }
            return nil
        }
        guard let user = percent("user"), let system = percent("sys"), let idle = percent("idle") else {
            return nil
        }
        return (
            min(100, max(0, user + system)),
            CPUBreakdown(
                user: user, system: system, iowait: 0, nice: 0,
                irq: 0, softirq: 0, steal: 0, idle: idle
            )
        )
    }

    private struct DarwinMemory {
        let total: Double
        let used: Double
        let cache: Double
        let free: Double
        let percent: Double
    }

    private static func parseMemory(total: String, vmstat: String) -> DarwinMemory? {
        guard let totalBytes = firstDouble(total), totalBytes > 0,
              let pageSize = number(after: "page size of", in: vmstat) else { return nil }
        let pages = vmStatValues(vmstat)
        let freePages = pages["Pages free"] ?? 0
        let cachePages = (pages["Pages inactive"] ?? 0)
            + (pages["Pages speculative"] ?? 0)
            + (pages["Pages purgeable"] ?? 0)
        let availableBytes = min(totalBytes, (freePages + cachePages) * pageSize)
        let usedBytes = max(0, totalBytes - availableBytes)
        return DarwinMemory(
            total: totalBytes,
            used: usedBytes,
            cache: cachePages * pageSize,
            free: freePages * pageSize,
            percent: usedBytes / totalBytes * 100
        )
    }

    private static func vmStatValues(_ section: String) -> [String: Double] {
        var values: [String: Double] = [:]
        for line in section.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let value = Double(raw) { values[key] = value }
        }
        return values
    }

    private static func parseSwap(_ section: String) -> (total: Double, used: Double)? {
        guard let total = byteValue(after: "total =", in: section),
              let used = byteValue(after: "used =", in: section) else { return nil }
        return (total, used)
    }

    private static func byteValue(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let token = tail.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
              let unit = token.last else { return nil }
        let numberText = token.dropLast()
        guard let value = Double(numberText) else { return nil }
        let multiplier: Double
        switch unit.uppercased() {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        default: return Double(token)
        }
        return value * multiplier
    }

    private static func parseLoad(_ section: String) -> LoadAverages? {
        guard let range = section.range(of: "load averages:") else { return nil }
        let values = section[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { Double($0) }
        guard values.count >= 3 else { return nil }
        return LoadAverages(one: values[0], five: values[1], fifteen: values[2])
    }

    private static func parseInterfaces(_ section: String) -> [RawInterface] {
        let lines = section.split(separator: "\n")
        guard let header = lines.first?.split(whereSeparator: { $0 == " " || $0 == "\t" }),
              let nameIndex = header.firstIndex(of: "Name"),
              let rxIndex = header.firstIndex(of: "Ibytes"),
              let txIndex = header.firstIndex(of: "Obytes") else { return [] }
        var maximums: [String: (rx: Int64, tx: Int64)] = [:]
        let requiredIndex = max(nameIndex, rxIndex, txIndex)
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > requiredIndex,
                  let rx = Int64(fields[rxIndex]), let tx = Int64(fields[txIndex]) else { continue }
            let name = String(fields[nameIndex])
            let old = maximums[name] ?? (0, 0)
            maximums[name] = (max(old.rx, rx), max(old.tx, tx))
        }
        return maximums.keys.sorted().compactMap { name in
            guard let value = maximums[name] else { return nil }
            return RawInterface(name: name, rx: value.rx, tx: value.tx)
        }
    }

    private static func interfaceTotals(_ interfaces: [RawInterface]) -> (rx: Int64, tx: Int64)? {
        let physical = interfaces.filter { !$0.name.hasPrefix("lo") }
        guard !physical.isEmpty else { return nil }
        return (physical.reduce(0) { $0 + $1.rx }, physical.reduce(0) { $0 + $1.tx })
    }

    private static func parseIPs(_ section: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        for line in section.split(separator: "\n") {
            if line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":") {
                current = String(line[..<colon])
                continue
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.first == "inet", fields.count > 1, let current {
                result[current] = String(fields[1])
            }
        }
        return result
    }

    private static func parseTCP(_ section: String) -> TCPStats? {
        func count(where predicate: (String) -> Bool) -> Int64? {
            for line in section.split(separator: "\n") {
                let text = String(line).trimmingCharacters(in: .whitespaces)
                if predicate(text), let value = Int64(text.split(separator: " ").first ?? "") {
                    return value
                }
            }
            return nil
        }
        let active = count { $0.contains("connection") && ($0.contains("initiated") || $0.contains("requests")) }
        let passive = count { $0.contains("connection") && ($0.contains("accepted") || $0.contains("accepts")) }
        let failures = count { $0.contains("bad connection attempts") }
        let sent = count { $0.contains("packets sent") }
        let retransmitted = count { $0.contains("data packets retransmitted") }
        guard let active, let passive, let failures, let sent, let retransmitted else { return nil }
        let rate = sent > 0 ? Double(retransmitted) / Double(sent) * 100 : 0
        return TCPStats(retransRate: rate, activeOpens: active, passiveOpens: passive, attemptFails: failures)
    }

    private static func parseIORegistry(_ section: String) -> (read: Int64, write: Int64)? {
        var read: Int64 = 0
        var write: Int64 = 0
        var matched = false
        for line in section.split(separator: "\n") {
            if let value = integer(after: "\"Bytes (Read)\"", in: String(line)) {
                read += value
                matched = true
            }
            if let value = integer(after: "\"Bytes (Write)\"", in: String(line)) {
                write += value
                matched = true
            }
        }
        return matched ? (read, write) : nil
    }

    private static func parseOS(_ section: String) -> String? {
        var values: [String: String] = [:]
        for line in section.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let name = values["ProductName"], let version = values["ProductVersion"] else { return nil }
        if let build = values["BuildVersion"], !build.isEmpty { return "\(name) \(version) (\(build))" }
        return "\(name) \(version)"
    }

    private static func firstNonemptyLine(_ section: String) -> String? {
        section.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    private static func firstDouble(_ text: String) -> Double? {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).compactMap { Double($0) }.first
    }

    private static func firstInt(_ text: String) -> Int? {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).compactMap { Int($0) }.first
    }

    private static func number(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        return text[range.upperBound...]
            .split(whereSeparator: { !$0.isNumber && $0 != "." })
            .compactMap { Double($0) }.first
    }

    private static func integer(after marker: String, in text: String) -> Int64? {
        guard let range = text.range(of: marker) else { return nil }
        return text[range.upperBound...]
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int64($0) }.first
    }
}
