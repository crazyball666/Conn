import ConnKit
import Foundation

/// 一次 Docker 能力探测得到的稳定执行上下文。
///
/// 后续所有 Docker 命令都必须复用这里的可执行路径，不能重新依赖远端非交互
/// shell 的 `PATH`。这对 Docker Desktop for Mac 尤其重要：CLI 可能只存在于 App
/// bundle 内，而不在 SSH 会话的默认 PATH 中。
public struct DockerRuntimeContext: Sendable, Equatable, Hashable {
    public let executable: String
    public let sudo: Bool
    /// 独立探测到的 Compose v1 CLI；不能假定它与 `docker` 位于同一目录。
    public let composeV1Executable: String?

    public init(executable: String, sudo: Bool, composeV1Executable: String? = nil) {
        self.executable = executable
        self.sudo = sudo
        self.composeV1Executable = composeV1Executable
    }

    /// 保留旧接口行为的默认上下文。
    public static let `default` = DockerRuntimeContext(executable: "docker", sudo: false)

    public func withSudo(_ sudo: Bool) -> DockerRuntimeContext {
        DockerRuntimeContext(
            executable: executable,
            sudo: sudo,
            composeV1Executable: composeV1Executable
        )
    }

    internal var executableCommand: String {
        executable == "docker" ? executable : ShellArgument.quote(executable)
    }

    internal var commandPrefix: String {
        (sudo ? "sudo -n " : "") + executableCommand
    }

    internal var composeV1CommandPrefix: String {
        let executable = composeV1Executable ?? "docker-compose"
        return (sudo ? "sudo -n " : "") + (executable == "docker-compose" ? executable : ShellArgument.quote(executable))
    }

    /// 为普通 shell 脚本注入一个名为 `docker` 的函数，使脚本中的标准 `docker …`
    /// 调用复用已探测到的 CLI 绝对路径与免密 sudo 决策。
    public var shellBootstrapCommand: String {
        "docker() { \(commandPrefix) \"$@\"; }"
    }
}

/// Docker 动态能力探测结果。平台画像是稳定事实；CLI、权限与 daemon 状态可能变化，
/// 因而单独返回并允许用户重试。
public struct DockerProbeResult: Sendable, Equatable {
    public let availability: DockerAvailability
    public let runtime: DockerRuntimeContext?

    public init(availability: DockerAvailability, runtime: DockerRuntimeContext?) {
        self.availability = availability
        self.runtime = runtime
    }
}
