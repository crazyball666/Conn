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

public extension DockerRuntimeContext {
    private static var composeV1Marker: String { "__CONN_COMPOSE_V1__" }

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
            []
        }
        guard !candidates.isEmpty else { return ":" }
        let composeCandidates = candidates.map { candidate in
            URL(fileURLWithPath: candidate)
                .deletingLastPathComponent()
                .appendingPathComponent("docker-compose")
                .path
        }
        let quoted = candidates.map(ShellArgument.quote).joined(separator: " ")
        let quotedCompose = composeCandidates.map(ShellArgument.quote).joined(separator: " ")
        return [
            "conn_docker_path=$(command -v docker 2>/dev/null || true)",
            "if [ -z \"$conn_docker_path\" ]; then for conn_candidate in \(quoted); do "
                + "test -x \"$conn_candidate\" && { conn_docker_path=\"$conn_candidate\"; break; }; done; fi",
            "[ -n \"$conn_docker_path\" ] && printf '%s\\n' \"$conn_docker_path\"",
            "conn_compose_path=$(command -v docker-compose 2>/dev/null || true)",
            "if [ -z \"$conn_compose_path\" ]; then for conn_candidate in \(quotedCompose); do "
                + "test -x \"$conn_candidate\" && { conn_compose_path=\"$conn_candidate\"; break; }; done; fi",
            "[ -n \"$conn_compose_path\" ] && printf '\(composeV1Marker)%s\\n' \"$conn_compose_path\"",
            "true",
        ].joined(separator: "; ")
    }

    static func parseDiscoveredExecutable(_ output: String) -> String? {
        output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix(composeV1Marker) }
    }

    static func parseDiscoveredComposeV1Executable(_ output: String) -> String? {
        output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(composeV1Marker) }
            .map { String($0.dropFirst(composeV1Marker.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
