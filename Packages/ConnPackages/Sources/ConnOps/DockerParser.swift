import Foundation

/// `docker ps` / `docker stats` 的 `{{json .}}` 输出解析与合并。纯函数、host 可测。
public enum DockerParser {
    /// 合并容器列表与资源快照。stats 只含运行中容器，按 id 前缀匹配并入。
    public static func parse(psOutput: String, statsOutput: String) -> [ContainerInfo] {
        let containers = parsePS(psOutput)
        let stats = parseStats(statsOutput)
        return containers.map { container in
            var merged = container
            // #11：精确匹配优先；否则前缀匹配——`docker ps` 给 12 位短 id，
            // 某些 docker 版本 `docker stats` 给 64 位全 id，直接查表会全 miss → 永远显示「—」。
            let stat = stats[container.id]
                ?? stats.first { $0.key.hasPrefix(container.id) || container.id.hasPrefix($0.key) }?.value
            if let stat {
                merged.cpuPercent = stat.cpu
                merged.memPercent = stat.mem
                merged.memUsage = stat.memUsage
            }
            return merged
        }
    }

    // MARK: - ps

    static func parsePS(_ output: String) -> [ContainerInfo] {
        decodeLines(output).map { (line: PSLine) in
            ContainerInfo(
                id: line.id,
                name: line.names,
                image: line.image,
                state: mapState(explicit: line.state, status: line.status),
                status: line.status,
                ports: line.ports ?? ""
            )
        }
    }

    /// State 字段是 Docker 20.10+ 才有；缺失时从 Status 串前缀推断（兼容旧版）。
    private static func mapState(explicit: String?, status: String) -> ContainerInfo.State {
        if let explicit, let mapped = ContainerInfo.State(rawValue: explicit.lowercased()) {
            return mapped
        }
        let lower = status.lowercased()
        if lower.hasPrefix("up") { return lower.contains("paused") ? .paused : .running }
        if lower.hasPrefix("exited") { return .exited }
        if lower.hasPrefix("created") { return .created }
        if lower.hasPrefix("restarting") { return .restarting }
        if lower.hasPrefix("dead") { return .dead }
        return .unknown
    }

    // MARK: - stats

    struct Stat: Equatable {
        let cpu: Double?
        let mem: Double?
        let memUsage: String
    }

    static func parseStats(_ output: String) -> [String: Stat] {
        var result: [String: Stat] = [:]
        for line: StatsLine in decodeLines(output) {
            result[line.id] = Stat(
                cpu: percent(line.cpuPerc),
                mem: percent(line.memPerc),
                memUsage: line.memUsage
            )
        }
        return result
    }

    // MARK: - 通用

    /// 逐行 JSON 解码，坏行跳过（docker 偶尔混入 warning 行）。
    private static func decodeLines<T: Decodable>(_ output: String) -> [T] {
        let decoder = JSONDecoder()
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    /// `12.34%` → 12.34；无效返回 nil。
    private static func percent(_ token: String) -> Double? {
        Double(token.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - JSON DTO（文件私有，避免类型嵌套过深）

private struct PSLine: Decodable {
    let id: String
    let image: String
    let names: String
    let state: String?
    let status: String
    let ports: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID", image = "Image", names = "Names"
        case state = "State", status = "Status", ports = "Ports"
    }
}

private struct StatsLine: Decodable {
    let id: String
    let cpuPerc: String
    let memPerc: String
    let memUsage: String

    enum CodingKeys: String, CodingKey {
        case id = "ID", cpuPerc = "CPUPerc", memPerc = "MemPerc", memUsage = "MemUsage"
    }
}
