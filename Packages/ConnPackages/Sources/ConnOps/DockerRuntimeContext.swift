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

    public init(executable: String, sudo: Bool) {
        self.executable = executable
        self.sudo = sudo
    }

    /// 保留旧接口行为的默认上下文。
    public static let `default` = DockerRuntimeContext(executable: "docker", sudo: false)

    public func withSudo(_ sudo: Bool) -> DockerRuntimeContext {
        DockerRuntimeContext(executable: executable, sudo: sudo)
    }

    internal var executableCommand: String {
        executable == "docker" ? executable : ShellArgument.quote(executable)
    }

    internal var commandPrefix: String {
        (sudo ? "sudo -n " : "") + executableCommand
    }

    internal var composeV1CommandPrefix: String {
        let executable: String
        if self.executable == "docker" {
            executable = "docker-compose"
        } else {
            let url = URL(fileURLWithPath: self.executable)
            executable = url.deletingLastPathComponent().appendingPathComponent("docker-compose").path
        }
        return (sudo ? "sudo -n " : "") + (executable == "docker-compose" ? executable : ShellArgument.quote(executable))
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

public extension DockerRuntimeContext {
    /// 按平台构造 Docker CLI 查找命令。macOS 额外覆盖 Intel/Homebrew 与
    /// Docker Desktop App bundle；输出最多一条可执行路径。
    static func discoveryCommand(for platform: RemotePlatformKind) -> String {
        let candidates: [String] = switch platform {
        case .macOS:
            [
                "/usr/local/bin/docker",
                "/opt/homebrew/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker",
            ]
        case .linux:
            ["/usr/bin/docker", "/usr/local/bin/docker"]
        case .windows, .unknown:
            ["/usr/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        }
        let quoted = candidates.map(ShellArgument.quote).joined(separator: " ")
        return "command -v docker 2>/dev/null || for conn_docker_path in \(quoted); do "
            + "test -x \"$conn_docker_path\" && { printf '%s\\n' \"$conn_docker_path\"; break; }; done"
    }

    static func parseDiscoveredExecutable(_ output: String) -> String? {
        output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
