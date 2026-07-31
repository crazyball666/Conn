import ConnSSH
import Foundation

/// Docker 可用性（方案 §4.4：无权限给引导文案而非静默失败）。
public enum DockerAvailability: Sendable, Equatable {
    /// docker ps 可直接跑；`sudo` 表示需否 `sudo -n` 前缀。
    case available(sudo: Bool)
    /// 未安装 docker CLI。
    case notInstalled
    /// 装了但当前用户无权限、且无免密 sudo。
    case permissionDenied
    /// 装了、有权限，但 Docker 守护进程没在跑。
    case daemonNotRunning

    /// 直接可用时用的 sudo 前缀标志；不可用时 false。
    public var sudo: Bool {
        if case let .available(sudo) = self { return sudo }
        return false
    }

    public var isUsable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// 容器管理服务：在一条已建立的会话上跑 docker CLI。
public enum DockerService {
    /// 单容器写操作（start/stop/restart/rm）的超时。
    ///
    /// 为什么不用 `exec(_:)` 默认的 30 秒：`docker stop` 先发 SIGTERM 再等宽限期，
    /// 默认就是 10 秒，容器自带更长的 `--stop-timeout`（或 restart = stop + start）
    /// 时轻易越过 30 秒；镜像层多的 `docker rmi` 也要等磁盘删完。
    /// 取 2 分钟：够覆盖正常的优雅停机，又不至于让一次误操作把 UI 挂太久。
    private static let writeTimeout: Duration = .seconds(120)

    /// 拉取镜像的超时。
    ///
    /// 拉取的镜像层大小和网络状况均不可预知；5 分钟内仍属正常范围。调用方用流式
    /// 输出展示进度，并在最终 `ExecResult` 到达后判定已知成功或失败。
    private static let pullTimeout: Duration = .seconds(300)

    /// 清理类操作（prune）的超时。
    ///
    /// 比单容器写操作更宽松：`docker image prune -a` 要遍历并删除全部未被引用的镜像层，
    /// 在镜像多、磁盘慢的主机上跑几分钟很常见——这属于正常执行，不该被判成失败
    /// （何况超时并不会终止远端的删除，见 `CitadelSession.exec`，半路「失败」只会让
    /// 用户以为没清理成功）。取 5 分钟。
    private static let pruneTimeout: Duration = .seconds(300)

    /// 探测可用性：先试直连，permission denied 再试 `sudo -n`。
    public static func probe(on session: any SSHSession) async throws -> DockerAvailability {
        let direct = try await session.exec(DockerCommand.availabilityProbe(sudo: false)).stdoutText
        if direct.contains("__EXIT__0") {
            return .available(sudo: false)
        }
        if direct.contains("not found") || direct.contains("command not found") {
            return .notInstalled
        }
        let elevated = try await session.exec(DockerCommand.availabilityProbe(sudo: true)).stdoutText
        if elevated.contains("__EXIT__0") {
            return .available(sudo: true)
        }
        // #20：守护进程没跑 vs 权限不足要分开——两者都提「docker daemon」，
        // 但守护进程停机是「Cannot connect / Is the docker daemon running」，权限是「permission denied」。
        if direct.contains("permission denied") {
            return .permissionDenied
        }
        if direct.contains("Cannot connect to the Docker daemon") || direct.contains("daemon running") {
            return .daemonNotRunning
        }
        return .permissionDenied
    }

    /// 列容器：并行拉 ps 与 stats 后合并。
    public static func list(on session: any SSHSession, sudo: Bool) async throws -> [ContainerInfo] {
        async let containerList = session.exec(DockerCommand.list(sudo: sudo))
        async let containerStats = session.exec(DockerCommand.stats(sudo: sudo))
        let (psResult, statsResult) = try await (containerList, containerStats)
        try requireQuerySuccess(psResult)
        return DockerParser.parse(psOutput: psResult.stdoutText, statsOutput: statsResult.stdoutText)
    }

    /// 执行容器写操作。返回 exec 结果供审计与错误呈现。
    public static func perform(
        _ action: ContainerAction,
        id: String,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.action(action, id: id, sudo: sudo), timeout: writeTimeout)
    }

    // MARK: - 第三期 Compose

    public static func composeDialect(
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> DockerComposeDialect? {
        let composeV2Result = try await session.exec(DockerCommand.composeVersion(.v2, sudo: sudo))
        if composeV2Result.exitCode == 0 {
            return .v2
        }
        let composeV1Result = try await session.exec(DockerCommand.composeVersion(.v1, sudo: sudo))
        return composeV1Result.exitCode == 0 ? .v1 : nil
    }

    public static func listComposeProjects(
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> [DockerComposeProject] {
        let listed: [DockerComposeProject]
        if dialect == .v2 {
            let result = try await session.exec(DockerCommand.composeProjects(sudo: sudo))
            try requireComposeSuccess(result)
            listed = DockerComposeParser.parseV2Projects(result.stdoutText)
        } else {
            listed = []
        }
        let containerResult = try await session.exec(
            DockerCommand.composeContainers(sudo: sudo)
        )
        try requireComposeSuccess(containerResult)
        let labeled = DockerComposeParser.parseProjectsFromContainers(containerResult.stdoutText)
        return DockerComposeParser.mergeDiscoveredProjects(listed: listed, labeled: labeled)
    }

    public static func composeServices(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> [DockerComposeService] {
        let config = try await session.exec(
            DockerCommand.composeConfigServices(project, dialect: dialect, sudo: sudo)
        )
        guard config.exitCode == 0 else {
            throw DockerComposeError.commandFailed(
                exitCode: config.exitCode,
                message: config.stderrText.isEmpty ? config.stdoutText : config.stderrText
            )
        }
        let declared = config.stdoutText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let containers = try await session.exec(
            DockerCommand.composeContainers(projectName: project.name, sudo: sudo)
        )
        guard containers.exitCode == 0 else {
            throw DockerComposeError.commandFailed(
                exitCode: containers.exitCode,
                message: containers.stderrText.isEmpty ? containers.stdoutText : containers.stderrText
            )
        }
        return DockerComposeParser.parseServices(
            containerOutput: containers.stdoutText,
            declaredServices: declared
        )
    }

    public static func composeUp(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.composeUp(project, dialect: dialect, sudo: sudo),
            timeout: writeTimeout
        )
    }

    public static func composeDown(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.composeDown(project, dialect: dialect, sudo: sudo),
            timeout: writeTimeout
        )
    }

    public static func composeRestart(
        _ project: DockerComposeProject,
        service: String? = nil,
        dialect: DockerComposeDialect,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(
            DockerCommand.composeRestart(
                project, service: service, dialect: dialect, sudo: sudo
            ),
            timeout: writeTimeout
        )
    }

    // MARK: - 第二期写操作

    /// 拉取镜像并实时返回远端输出；最终退出结果由流的 `result()` 提供。
    public static func pullImage(
        reference: String, on session: any SSHSession, sudo: Bool
    ) async throws -> SSHCommandStream {
        try await session.execCommandStream(
            DockerCommand.pull(reference: reference, sudo: sudo), timeout: pullTimeout
        )
    }

    /// 根据已校验的草稿创建容器。
    public static func runContainer(
        _ draft: DockerRunDraft, on session: any SSHSession, sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.run(draft, sudo: sudo), timeout: writeTimeout)
    }

    /// 创建卷。
    public static func createVolume(
        _ draft: DockerVolumeDraft, on session: any SSHSession, sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.createVolume(draft, sudo: sudo), timeout: writeTimeout)
    }

    /// 删除卷。
    public static func removeVolume(
        name: String, on session: any SSHSession, sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.removeVolume(name: name, sudo: sudo), timeout: writeTimeout)
    }

    /// 创建网络。
    public static func createNetwork(
        _ draft: DockerNetworkDraft, on session: any SSHSession, sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.createNetwork(draft, sudo: sudo), timeout: writeTimeout)
    }

    /// 删除网络。
    public static func removeNetwork(
        name: String, on session: any SSHSession, sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.removeNetwork(name: name, sudo: sudo), timeout: writeTimeout)
    }

    /// 清理未使用 Docker 资源。
    public static func systemPrune(
        _ options: DockerSystemPruneOptions, on session: any SSHSession, sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.systemPrune(options, sudo: sudo), timeout: pruneTimeout)
    }

    /// 列镜像。
    public static func listImages(on session: any SSHSession, sudo: Bool) async throws -> [ImageInfo] {
        let result = try await session.exec(DockerCommand.images(sudo: sudo))
        try requireQuerySuccess(result)
        return DockerParser.parseImages(result.stdoutText)
    }

    /// 删除镜像。
    public static func removeImage(
        reference: String, on session: any SSHSession, sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.removeImage(reference: reference, sudo: sudo), timeout: writeTimeout)
    }

    /// 清理悬空镜像。
    public static func pruneImages(on session: any SSHSession, sudo: Bool) async throws -> ExecResult {
        try await session.exec(DockerCommand.pruneImages(sudo: sudo), timeout: pruneTimeout)
    }

    // MARK: - 卷

    public static func listVolumes(on session: any SSHSession, sudo: Bool) async throws -> [VolumeInfo] {
        let result = try await session.exec(DockerCommand.volumes(sudo: sudo))
        try requireQuerySuccess(result)
        return DockerParser.parseVolumes(result.stdoutText)
    }

    public static func danglingVolumeNames(on session: any SSHSession, sudo: Bool) async throws -> Set<String> {
        let result = try await session.exec(DockerCommand.danglingVolumes(sudo: sudo))
        try requireQuerySuccess(result)
        return DockerParser.parseNameList(result.stdoutText)
    }

    /// 引用某卷的容器。含已停止的——它引用着就删不掉该卷。
    public static func containersUsingVolume(
        name: String, on session: any SSHSession, sudo: Bool
    ) async throws -> [ContainerInfo] {
        let result = try await session.exec(DockerCommand.containersUsingVolume(name: name, sudo: sudo))
        try requireQuerySuccess(result)
        return DockerParser.parsePS(result.stdoutText)
    }

    // MARK: - 网络

    public static func listNetworks(on session: any SSHSession, sudo: Bool) async throws -> [NetworkInfo] {
        let result = try await session.exec(DockerCommand.networks(sudo: sudo))
        try requireQuerySuccess(result)
        return DockerParser.parseNetworks(result.stdoutText)
    }

    public static func danglingNetworkNames(on session: any SSHSession, sudo: Bool) async throws -> Set<String> {
        let result = try await session.exec(DockerCommand.danglingNetworks(sudo: sudo))
        try requireQuerySuccess(result)
        return DockerParser.parseNameList(result.stdoutText)
    }

    // MARK: - 镜像详情

    public static func imageHistory(
        reference: String, on session: any SSHSession, sudo: Bool
    ) async throws -> [ImageLayer] {
        let result = try await session.exec(DockerCommand.imageHistory(reference: reference, sudo: sudo))
        try requireQuerySuccess(result)
        return DockerParser.parseImageHistory(result.stdoutText)
    }

    // MARK: - 磁盘占用

    /// 磁盘占用。**格式不支持时返回 nil 而不抛错**——它只是锦上添花的字段，
    /// 抛错会让调用方以为整页坏了。
    public static func diskUsage(on session: any SSHSession, sudo: Bool) async throws -> DockerDiskUsage? {
        let result = try await session.exec(DockerCommand.diskUsage(sudo: sudo), timeout: .seconds(30))
        try requireQuerySuccess(result)
        return DockerParser.parseDiskUsage(result.stdoutText)
    }

    /// 跟随容器日志流。
    public static func logStream(
        id: String,
        tail: Int = 200,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await session.execStream(DockerCommand.logs(id: id, tail: tail, sudo: sudo))
    }

    private static func requireComposeSuccess(_ result: ExecResult) throws {
        guard result.exitCode == 0 else {
            throw DockerComposeError.commandFailed(
                exitCode: result.exitCode,
                message: result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            )
        }
    }

}
