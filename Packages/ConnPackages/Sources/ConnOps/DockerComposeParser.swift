import Foundation

public enum DockerComposeParser {
    public static func parseV2Projects(_ output: String) -> [DockerComposeProject] {
        guard let data = output.data(using: .utf8),
              let rows = try? JSONDecoder().decode([ProjectRow].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            let files = splitConfigFiles(row.configFiles)
            guard !row.name.isEmpty, let firstFile = files.first else { return nil }
            return DockerComposeProject(
                name: row.name,
                state: state(fromComposeStatus: row.status),
                configFiles: files,
                projectDirectory: URL(fileURLWithPath: firstFile).deletingLastPathComponent().path,
                source: .automatic
            )
        }
        .sorted { $0.name < $1.name }
    }

    public static func parseProjectsFromContainers(_ output: String) -> [DockerComposeProject] {
        let containers = parseContainers(output)
        return Dictionary(grouping: containers, by: \.project)
            .compactMap { name, rows in
                guard !name.isEmpty else { return nil }
                let configFiles = rows.lazy.map(\.configFiles).first { !$0.isEmpty } ?? []
                let explicitDirectory = rows.lazy.map(\.projectDirectory).first { !$0.isEmpty }
                let fallbackDirectory = configFiles.first.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().path
                } ?? ""
                let services = Set(rows.map(\.service).filter { !$0.isEmpty })
                return DockerComposeProject(
                    name: name,
                    state: aggregateState(rows.map(\.state), hasKnownServices: !services.isEmpty),
                    configFiles: configFiles,
                    projectDirectory: explicitDirectory ?? fallbackDirectory,
                    source: .automatic,
                    serviceCount: services.count,
                    containerCount: rows.count,
                    runningContainerCount: rows.count { normalizedState($0.state) == "running" }
                )
            }
            .sorted { $0.name < $1.name }
    }

    public static func parseServices(
        containerOutput: String,
        declaredServices: [String]
    ) -> [DockerComposeService] {
        let containers = parseContainers(containerOutput)
        let grouped = Dictionary(grouping: containers.filter { !$0.service.isEmpty }, by: \.service)
        let names = Set(declaredServices).union(grouped.keys)
        return names.map { name in
            let rows = grouped[name] ?? []
            let images = rows.map(\.image).filter { !$0.isEmpty }
            let statuses = rows.map(\.status).filter { !$0.isEmpty }
            let ports = rows.map(\.ports).filter { !$0.isEmpty }
            return DockerComposeService(
                name: name,
                image: images.first,
                state: aggregateState(rows.map(\.state), hasKnownServices: true),
                containerCount: rows.count,
                runningContainerCount: rows.count { normalizedState($0.state) == "running" },
                status: statuses.isEmpty ? "—" : statuses.joined(separator: " · "),
                ports: ports.joined(separator: " · ")
            )
        }
        .sorted { $0.name < $1.name }
    }

    public static func mergeProjects(
        discovered: [DockerComposeProject],
        manual: [DockerComposeProject]
    ) -> [DockerComposeProject] {
        var byName = Dictionary(uniqueKeysWithValues: discovered.map { ($0.name, $0) })
        for manualProject in manual {
            if let automatic = byName[manualProject.name] {
                var merged = manualProject
                merged.state = automatic.state
                merged.serviceCount = automatic.serviceCount
                merged.containerCount = automatic.containerCount
                merged.runningContainerCount = automatic.runningContainerCount
                byName[manualProject.name] = merged
            } else {
                byName[manualProject.name] = manualProject
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    public static func mergeDiscoveredProjects(
        listed: [DockerComposeProject],
        labeled: [DockerComposeProject]
    ) -> [DockerComposeProject] {
        var byName = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0) })
        for labeledProject in labeled {
            if var project = byName[labeledProject.name] {
                if !labeledProject.configFiles.isEmpty {
                    project.configFiles = labeledProject.configFiles
                }
                if !labeledProject.projectDirectory.isEmpty {
                    project.projectDirectory = labeledProject.projectDirectory
                }
                if labeledProject.state != .unknown {
                    project.state = labeledProject.state
                }
                project.serviceCount = labeledProject.serviceCount
                project.containerCount = labeledProject.containerCount
                project.runningContainerCount = labeledProject.runningContainerCount
                byName[labeledProject.name] = project
            } else {
                byName[labeledProject.name] = labeledProject
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    private static func parseContainers(_ output: String) -> [ContainerRow] {
        output.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let row = try? JSONDecoder().decode(ContainerJSONRow.self, from: data),
                  let project = composeLabel("com.docker.compose.project", in: row.labels),
                  !project.isEmpty
            else { return nil }
            let configFiles = composeLabel(
                "com.docker.compose.project.config_files", in: row.labels
            ).map(splitConfigFiles) ?? []
            return ContainerRow(
                image: row.image,
                state: row.state,
                status: row.status,
                ports: row.ports ?? "",
                project: project,
                service: composeLabel("com.docker.compose.service", in: row.labels) ?? "",
                configFiles: configFiles,
                projectDirectory: composeLabel(
                    "com.docker.compose.project.working_dir", in: row.labels
                ) ?? ""
            )
        }
    }

    private static func composeLabel(_ key: String, in labels: String) -> String? {
        let marker = key + "="
        guard let markerRange = labels.range(of: marker),
              markerRange.lowerBound == labels.startIndex
                || labels[labels.index(before: markerRange.lowerBound)] == ","
        else { return nil }
        let tail = labels[markerRange.upperBound...]
        let composeMarker = ",com.docker.compose."
        if let next = tail.range(of: composeMarker) {
            return String(tail[..<next.lowerBound])
        }
        return String(tail)
    }

    private static func splitConfigFiles(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func state(fromComposeStatus value: String) -> DockerComposeState {
        let lower = value.lowercased()
        if lower.contains("running") { return .running }
        if lower.contains("exited") || lower.contains("stopped") { return .stopped }
        return .unknown
    }

    private static func aggregateState(
        _ values: [String],
        hasKnownServices: Bool
    ) -> DockerComposeState {
        guard !values.isEmpty else { return hasKnownServices ? .stopped : .unknown }
        let normalized = values.map(normalizedState)
        if normalized.allSatisfy({ $0 == "running" }) {
            return .running
        }
        if normalized.contains(where: { $0 == "running" || $0 == "restarting" || $0 == "paused" }) {
            return .partial
        }
        return .stopped
    }

    private static func normalizedState(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "running" || lower.hasPrefix("up") { return "running" }
        if lower == "restarting" { return "restarting" }
        if lower == "paused" || lower.contains("paused") { return "paused" }
        return lower
    }
}

private struct ProjectRow: Decodable {
    let name: String
    let status: String
    let configFiles: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case status = "Status"
        case configFiles = "ConfigFiles"
    }
}

private struct ContainerJSONRow: Decodable {
    let image: String
    let state: String
    let status: String
    let ports: String?
    let labels: String

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case labels = "Labels"
    }
}

private struct ContainerRow {
    let image: String
    let state: String
    let status: String
    let ports: String
    let project: String
    let service: String
    let configFiles: [String]
    let projectDirectory: String
}
