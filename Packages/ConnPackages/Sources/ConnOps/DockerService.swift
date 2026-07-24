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
        async let ps = session.exec(DockerCommand.list(sudo: sudo))
        async let stats = session.exec(DockerCommand.stats(sudo: sudo))
        let (psResult, statsResult) = try await (ps, stats)
        return DockerParser.parse(psOutput: psResult.stdoutText, statsOutput: statsResult.stdoutText)
    }

    /// 执行容器写操作。返回 exec 结果供审计与错误呈现。
    public static func perform(
        _ action: ContainerAction,
        id: String,
        on session: any SSHSession,
        sudo: Bool
    ) async throws -> ExecResult {
        try await session.exec(DockerCommand.action(action, id: id, sudo: sudo))
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
}
