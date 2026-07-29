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

    // MARK: - 镜像详情

    /// `docker image inspect <引用>`（JSON 数组，取首个）。空/坏输出返回 nil。
    public static func parseImageInspect(_ output: String) -> ImageDetail? {
        guard let dto: ImageInspectDTO = decodeFirst(output) else { return nil }
        let bareID = dto.id.hasPrefix("sha256:") ? String(dto.id.dropFirst(7)) : dto.id
        let entrypoint = (dto.config?.entrypoint ?? []).joined(separator: " ")
        let command = (dto.config?.cmd ?? []).joined(separator: " ")
        return ImageDetail(
            id: String(bareID.prefix(12)),
            tags: dto.repoTags ?? [],
            digest: dto.repoDigests?.first,
            architecture: dto.architecture ?? "—",
            os: dto.os ?? "—",
            sizeBytes: dto.size ?? 0,
            entrypoint: entrypoint.isEmpty ? nil : entrypoint,
            command: command.isEmpty ? nil : command,
            env: (dto.config?.env ?? []).sorted(),
            labels: keyValueList(dto.config?.labels),
            created: shortDate(dto.created ?? "")
        )
    }

    public static func parseImageHistory(_ output: String) -> [ImageLayer] {
        decodeLines(output).map { (line: HistoryLine) in
            ImageLayer(
                id: line.id,
                createdBy: line.createdBy,
                size: line.size,
                createdSince: line.createdSince
            )
        }
    }

    // MARK: - 卷

    public static func parseVolumes(_ output: String) -> [VolumeInfo] {
        decodeLines(output).map { (line: VolumeLine) in
            VolumeInfo(
                name: line.name,
                driver: line.driver,
                scope: line.scope ?? "local",
                mountpoint: line.mountpoint ?? "—"
            )
        }
    }

    /// `docker volume inspect <名>`（JSON 数组，取首个）。空/坏输出返回 nil。
    public static func parseVolumeInspect(_ output: String) -> VolumeDetail? {
        guard let dto: VolumeInspectDTO = decodeFirst(output) else { return nil }
        return VolumeDetail(
            name: dto.name,
            driver: dto.driver,
            mountpoint: dto.mountpoint ?? "—",
            createdAt: shortDate(dto.createdAt ?? ""),
            labels: keyValueList(dto.labels),
            options: keyValueList(dto.options)
        )
    }

    // MARK: - 网络

    public static func parseNetworks(_ output: String) -> [NetworkInfo] {
        decodeLines(output).map { (line: NetworkLine) in
            NetworkInfo(id: line.id, name: line.name, driver: line.driver, scope: line.scope ?? "local")
        }
    }

    /// `docker network inspect <名>`（JSON 数组，取首个）。空/坏输出返回 nil。
    public static func parseNetworkInspect(_ output: String) -> NetworkDetail? {
        guard let dto: NetworkInspectDTO = decodeFirst(output) else { return nil }
        let ipam = dto.ipam?.config?.first
        let attached = (dto.containers ?? [:])
            .map { id, container in
                NetworkDetail.AttachedContainer(id: id, name: container.name ?? id, ipv4: container.ipv4Address)
            }
            // JSON 字典无序：不排序则每次刷新顺序都可能变，UI 会莫名跳动
            .sorted { $0.name < $1.name }
        return NetworkDetail(
            id: dto.id,
            name: dto.name,
            driver: dto.driver ?? "—",
            scope: dto.scope ?? "local",
            subnet: ipam?.subnet,
            gateway: ipam?.gateway,
            isInternal: dto.isInternal ?? false,
            attachedContainers: attached
        )
    }

    /// `ls --filter dangling=true` 的名字输出 → 集合。空行剔除。
    public static func parseNameList(_ output: String) -> Set<String> {
        Set(
            output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
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

    /// JSON 数组取首个元素解码。`docker X inspect` 全都是这个形状。
    private static func decodeFirst<T: Decodable>(_ output: String) -> T? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([T].self, from: data))?.first
    }

    /// `{"a":"1","b":"2"}` → `["a=1", "b=2"]`。已排序，nil 得空数组。
    private static func keyValueList(_ dict: [String: String]?) -> [String] {
        (dict ?? [:]).map { "\($0.key)=\($0.value)" }.sorted()
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

// MARK: - 卷 / 网络 DTO

private struct VolumeLine: Decodable {
    let name: String
    let driver: String
    let scope: String?
    let mountpoint: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", scope = "Scope", mountpoint = "Mountpoint"
    }
}

private struct NetworkLine: Decodable {
    let id: String
    let name: String
    let driver: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "Name", driver = "Driver", scope = "Scope"
    }
}

private struct VolumeInspectDTO: Decodable {
    let name: String
    let driver: String
    let mountpoint: String?
    let createdAt: String?
    let labels: [String: String]?
    let options: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", mountpoint = "Mountpoint"
        case createdAt = "CreatedAt", labels = "Labels", options = "Options"
    }
}

private struct NetworkInspectDTO: Decodable {
    let id: String
    let name: String
    let driver: String?
    let scope: String?
    let isInternal: Bool?
    let ipam: NetworkIPAM?
    let containers: [String: NetworkContainerDTO]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", driver = "Driver", scope = "Scope"
        case isInternal = "Internal", ipam = "IPAM", containers = "Containers"
    }
}

private struct NetworkIPAM: Decodable {
    let config: [NetworkIPAMConfig]?
    enum CodingKeys: String, CodingKey { case config = "Config" }
}

private struct NetworkIPAMConfig: Decodable {
    let subnet: String?
    let gateway: String?
    enum CodingKeys: String, CodingKey { case subnet = "Subnet", gateway = "Gateway" }
}

private struct NetworkContainerDTO: Decodable {
    let name: String?
    let ipv4Address: String?
    enum CodingKeys: String, CodingKey { case name = "Name", ipv4Address = "IPv4Address" }
}

// MARK: - 镜像详情 DTO

private struct ImageInspectDTO: Decodable {
    let id: String
    let repoTags: [String]?
    let repoDigests: [String]?
    let created: String?
    let size: Int64?
    let architecture: String?
    let os: String?
    let config: ImageConfigDTO?

    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", repoDigests = "RepoDigests"
        case created = "Created", size = "Size", architecture = "Architecture"
        case os = "Os", config = "Config"
    }
}

private struct ImageConfigDTO: Decodable {
    let entrypoint: [String]?
    let cmd: [String]?
    let env: [String]?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case entrypoint = "Entrypoint", cmd = "Cmd", env = "Env", labels = "Labels"
    }
}

private struct HistoryLine: Decodable {
    let id: String
    let createdBy: String
    let size: String
    let createdSince: String

    enum CodingKeys: String, CodingKey {
        case id = "ID", createdBy = "CreatedBy", size = "Size", createdSince = "CreatedSince"
    }
}
