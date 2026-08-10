import ConnSSH
import Foundation

/// 使用已探测 Docker CLI 路径的服务入口。旧 `sudo:` API 仍保留用于源码兼容；
/// App 与新调用应只传递 `DockerRuntimeContext`。
public extension DockerService {
    static func list(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> [ContainerInfo] {
        async let containerList = session.exec(DockerCommand.list(runtime: runtime))
        async let containerStats = session.exec(DockerCommand.stats(runtime: runtime))
        let (psResult, statsResult) = try await (containerList, containerStats)
        try requireQuerySuccess(psResult)
        return DockerParser.parse(psOutput: psResult.stdoutText, statsOutput: statsResult.stdoutText)
    }

    static func perform(
        _ action: ContainerAction,
        id: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.action(action, id: id, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func composeDialect(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> DockerComposeDialect? {
        let composeV2Result = try await session.exec(
            DockerCommand.composeVersion(.v2, runtime: runtime)
        )
        if composeV2Result.exitCode == 0 {
            return .v2
        }
        let composeV1Result = try await session.exec(
            DockerCommand.composeVersion(.v1, runtime: runtime)
        )
        return composeV1Result.exitCode == 0 ? .v1 : nil
    }

    static func listComposeProjects(
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> [DockerComposeProject] {
        let listed: [DockerComposeProject]
        if dialect == .v2 {
            let result = try await session.exec(DockerCommand.composeProjects(runtime: runtime))
            try requireComposeSuccess(result)
            listed = DockerComposeParser.parseV2Projects(result.stdoutText)
        } else {
            listed = []
        }
        let containerResult = try await session.exec(
            DockerCommand.composeContainers(runtime: runtime)
        )
        try requireComposeSuccess(containerResult)
        let labeled = DockerComposeParser.parseProjectsFromContainers(containerResult.stdoutText)
        return DockerComposeParser.mergeDiscoveredProjects(listed: listed, labeled: labeled)
    }

    static func composeServices(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> [DockerComposeService] {
        let config = try await session.exec(
            DockerCommand.composeConfigServices(project, dialect: dialect, runtime: runtime)
        )
        try requireComposeSuccess(config)
        let declared = config.stdoutText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let containers = try await session.exec(
            DockerCommand.composeContainers(projectName: project.name, runtime: runtime)
        )
        try requireComposeSuccess(containers)
        return DockerComposeParser.parseServices(
            containerOutput: containers.stdoutText,
            declaredServices: declared
        )
    }

    static func composeUp(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.composeUp(project, dialect: dialect, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func composeDown(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.composeDown(project, dialect: dialect, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func composeRestart(
        _ project: DockerComposeProject,
        service: String? = nil,
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.composeRestart(
                project,
                service: service,
                dialect: dialect,
                runtime: runtime
            ),
            timeout: writeTimeout
        )
    }

    static func pullImage(
        reference: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> SSHCommandStream {
        try await session.execCommandStream(
            DockerCommand.pull(reference: reference, runtime: runtime),
            timeout: pullTimeout
        )
    }

    static func runContainer(
        _ draft: DockerRunDraft,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.run(draft, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func createVolume(
        _ draft: DockerVolumeDraft,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.createVolume(draft, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func removeVolume(
        name: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.removeVolume(name: name, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func createNetwork(
        _ draft: DockerNetworkDraft,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.createNetwork(draft, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func removeNetwork(
        name: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.removeNetwork(name: name, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func systemPrune(
        _ options: DockerSystemPruneOptions,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.systemPrune(options, runtime: runtime),
            timeout: pruneTimeout
        )
    }

    static func listImages(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> [ImageInfo] {
        let result = try await session.exec(DockerCommand.images(runtime: runtime))
        try requireQuerySuccess(result)
        return DockerParser.parseImages(result.stdoutText)
    }

    static func removeImage(
        reference: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.removeImage(reference: reference, runtime: runtime),
            timeout: writeTimeout
        )
    }

    static func pruneImages(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.pruneImages(runtime: runtime),
            timeout: pruneTimeout
        )
    }

    static func listVolumes(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> [VolumeInfo] {
        let result = try await session.exec(DockerCommand.volumes(runtime: runtime))
        try requireQuerySuccess(result)
        return DockerParser.parseVolumes(result.stdoutText)
    }

    static func danglingVolumeNames(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> Set<String> {
        let result = try await session.exec(DockerCommand.danglingVolumes(runtime: runtime))
        try requireQuerySuccess(result)
        return DockerParser.parseNameList(result.stdoutText)
    }

    static func containersUsingVolume(
        name: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> [ContainerInfo] {
        let result = try await session.exec(
            DockerCommand.containersUsingVolume(name: name, runtime: runtime)
        )
        try requireQuerySuccess(result)
        return DockerParser.parsePS(result.stdoutText)
    }

    static func listNetworks(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> [NetworkInfo] {
        let result = try await session.exec(DockerCommand.networks(runtime: runtime))
        try requireQuerySuccess(result)
        return DockerParser.parseNetworks(result.stdoutText)
    }

    static func danglingNetworkNames(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> Set<String> {
        let result = try await session.exec(DockerCommand.danglingNetworks(runtime: runtime))
        try requireQuerySuccess(result)
        return DockerParser.parseNameList(result.stdoutText)
    }

    static func imageHistory(
        reference: String,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> [ImageLayer] {
        let result = try await session.exec(
            DockerCommand.imageHistory(reference: reference, runtime: runtime)
        )
        try requireQuerySuccess(result)
        return DockerParser.parseImageHistory(result.stdoutText)
    }

    static func diskUsage(
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> DockerDiskUsage? {
        let result = try await session.exec(
            DockerCommand.diskUsage(runtime: runtime),
            timeout: .seconds(30)
        )
        try requireQuerySuccess(result)
        return DockerParser.parseDiskUsage(result.stdoutText)
    }

    static func logStream(
        id: String,
        tail: Int = 200,
        on session: any SSHSession,
        runtime: DockerRuntimeContext
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await session.execStream(
            DockerCommand.logs(id: id, tail: tail, runtime: runtime)
        )
    }
}
