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
                merged.netIO = stat.netIO
                merged.blockIO = stat.blockIO
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
        let netIO: String?
        let blockIO: String?
    }

    static func parseStats(_ output: String) -> [String: Stat] {
        var result: [String: Stat] = [:]
        for line: StatsLine in decodeLines(output) {
            result[line.id] = Stat(
                cpu: percent(line.cpuPerc),
                mem: percent(line.memPerc),
                memUsage: line.memUsage,
                netIO: line.netIO,
                blockIO: line.blockIO
            )
        }
        return result
    }

    // MARK: - images

    public static func parseImages(_ output: String) -> [ImageInfo] {
        decodeLines(output).map { (line: ImageLine) in
            ImageInfo(
                imageID: line.id, repository: line.repository, tag: line.tag,
                size: line.size, created: line.createdSince
            )
        }
    }

    // MARK: - inspect

    /// `docker inspect <id>`（JSON 数组，取首个）→ 运维摘要。空/坏输出返回 nil。
    public static func parseInspect(_ output: String) -> ContainerDetail? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let dto = (try? JSONDecoder().decode([InspectDTO].self, from: data))?.first
        else { return nil }

        let command = ([dto.path].compactMap { $0 } + (dto.args ?? []))
            .joined(separator: " ")
        let ports = (dto.networkSettings?.ports ?? [:]).flatMap { port, bindings -> [String] in
            (bindings ?? []).map { "\($0.hostIp ?? "0.0.0.0"):\($0.hostPort ?? "?")->\(port)" }
        }.sorted()
        let mounts = (dto.mounts ?? []).map {
            "\($0.source ?? "?") → \($0.destination ?? "?")\(($0.rw ?? true) ? "" : " (ro)")"
        }
        let networks = (dto.networkSettings?.networks ?? [:]).map { name, net in
            net.ipAddress.map { $0.isEmpty ? name : "\(name) · \($0)" } ?? name
        }.sorted()

        return ContainerDetail(
            id: String(dto.id.prefix(12)),
            name: dto.name.hasPrefix("/") ? String(dto.name.dropFirst()) : dto.name,
            image: dto.config?.image ?? dto.image ?? "—",
            command: command.isEmpty ? (dto.config?.cmd ?? []).joined(separator: " ") : command,
            created: shortDate(dto.created),
            statusText: dto.state.status,
            startedAt: shortDate(dto.state.startedAt ?? ""),
            restartCount: dto.restartCount ?? 0,
            restartPolicy: dto.hostConfig?.restartPolicy?.name ?? "—",
            health: dto.state.health?.status,
            ports: ports,
            mounts: mounts,
            networks: networks,
            env: dto.config?.env ?? []
        )
    }

    /// ISO8601（`2024-01-15T06:13:00.123Z`）→ `2024-01-15 06:13`。空串返回「—」。
    private static func shortDate(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso.isEmpty ? "—" : iso }
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
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
    let netIO: String?
    let blockIO: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID", cpuPerc = "CPUPerc", memPerc = "MemPerc", memUsage = "MemUsage"
        case netIO = "NetIO", blockIO = "BlockIO"
    }
}

private struct ImageLine: Decodable {
    let id: String
    let repository: String
    let tag: String
    let size: String
    let createdSince: String

    enum CodingKeys: String, CodingKey {
        case id = "ID", repository = "Repository", tag = "Tag", size = "Size", createdSince = "CreatedSince"
    }
}

// MARK: - inspect DTO（映射 `docker inspect` 关注字段；各层平铺以满足 nesting≤1）

private struct InspectDTO: Decodable {
    let id: String
    let name: String
    let created: String
    let path: String?
    let args: [String]?
    let image: String?
    let restartCount: Int?
    let state: InspectState
    let config: InspectConfig?
    let hostConfig: InspectHostConfig?
    let networkSettings: InspectNetworkSettings?
    let mounts: [InspectMount]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", created = "Created", path = "Path", args = "Args"
        case image = "Image", restartCount = "RestartCount", state = "State", config = "Config"
        case hostConfig = "HostConfig", networkSettings = "NetworkSettings", mounts = "Mounts"
    }
}

private struct InspectState: Decodable {
    let status: String
    let startedAt: String?
    let health: InspectHealth?
    enum CodingKeys: String, CodingKey { case status = "Status", startedAt = "StartedAt", health = "Health" }
}

private struct InspectHealth: Decodable {
    let status: String
    enum CodingKeys: String, CodingKey { case status = "Status" }
}

private struct InspectConfig: Decodable {
    let image: String?
    let env: [String]?
    let cmd: [String]?
    enum CodingKeys: String, CodingKey { case image = "Image", env = "Env", cmd = "Cmd" }
}

private struct InspectHostConfig: Decodable {
    let restartPolicy: InspectRestartPolicy?
    enum CodingKeys: String, CodingKey { case restartPolicy = "RestartPolicy" }
}

private struct InspectRestartPolicy: Decodable {
    let name: String?
    enum CodingKeys: String, CodingKey { case name = "Name" }
}

private struct InspectNetworkSettings: Decodable {
    let ports: [String: [InspectPortBinding]?]?
    let networks: [String: InspectNetwork]?
    enum CodingKeys: String, CodingKey { case ports = "Ports", networks = "Networks" }
}

private struct InspectPortBinding: Decodable {
    let hostIp: String?
    let hostPort: String?
    enum CodingKeys: String, CodingKey { case hostIp = "HostIp", hostPort = "HostPort" }
}

private struct InspectNetwork: Decodable {
    let ipAddress: String?
    enum CodingKeys: String, CodingKey { case ipAddress = "IPAddress" }
}

private struct InspectMount: Decodable {
    let source: String?
    let destination: String?
    let rw: Bool?
    enum CodingKeys: String, CodingKey { case source = "Source", destination = "Destination", rw = "RW" }
}
