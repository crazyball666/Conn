import ConnKit
import ConnSSH
import Foundation

/// 一个平台的 Docker CLI 发现与运行时可用性探测能力。
public protocol DockerEnvironmentProvider: Sendable {
    var platform: RemotePlatformKind { get }
    func probe(on session: any SSHSession) async throws -> DockerProbeResult
}

public struct LinuxDockerEnvironmentProvider: DockerEnvironmentProvider {
    public let platform = RemotePlatformKind.linux

    public init() {}

    public func probe(on session: any SSHSession) async throws -> DockerProbeResult {
        try await POSIXDockerEnvironmentProbe.probe(
            on: session,
            executableCandidates: ["/usr/bin/docker", "/usr/local/bin/docker"]
        )
    }
}

public struct DarwinDockerEnvironmentProvider: DockerEnvironmentProvider {
    public let platform = RemotePlatformKind.macOS

    public init() {}

    public func probe(on session: any SSHSession) async throws -> DockerProbeResult {
        try await POSIXDockerEnvironmentProbe.probe(
            on: session,
            executableCandidates: [
                "/usr/local/bin/docker",
                "/opt/homebrew/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker",
            ]
        )
    }
}

/// 按远端平台选择 Docker 环境 provider；可注入自定义 provider 供组合与测试。
public struct DockerEnvironmentProviderRegistry: Sendable {
    private let providers: [RemotePlatformKind: any DockerEnvironmentProvider]

    public static let `default` = DockerEnvironmentProviderRegistry(providers: [
        LinuxDockerEnvironmentProvider(),
        DarwinDockerEnvironmentProvider(),
    ])

    public init(providers: [any DockerEnvironmentProvider]) {
        self.providers = Dictionary(
            providers.map { ($0.platform, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
    }

    public func provider(for platform: RemotePlatformKind) -> (any DockerEnvironmentProvider)? {
        providers[platform]
    }
}

private enum POSIXDockerEnvironmentProbe {
    private static let composeV1Marker = "__CONN_COMPOSE_V1__"

    static func probe(
        on session: any SSHSession,
        executableCandidates: [String]
    ) async throws -> DockerProbeResult {
        let discovery = try await session.exec(
            discoveryCommand(executableCandidates: executableCandidates)
        )
        guard let executable = parseDiscoveredExecutable(discovery.stdoutText) else {
            return DockerProbeResult(availability: .notInstalled, runtime: nil)
        }
        let composeV1Executable = parseDiscoveredComposeV1Executable(discovery.stdoutText)

        let directRuntime = DockerRuntimeContext(
            executable: executable,
            sudo: false,
            composeV1Executable: composeV1Executable
        )
        let direct = try await session.exec(
            DockerCommand.availabilityProbe(runtime: directRuntime)
        ).stdoutText
        if direct.contains("__EXIT__0") {
            return DockerProbeResult(
                availability: .available(sudo: false),
                runtime: directRuntime
            )
        }

        let elevatedRuntime = directRuntime.withSudo(true)
        let elevated = try await session.exec(
            DockerCommand.availabilityProbe(runtime: elevatedRuntime)
        ).stdoutText
        if elevated.contains("__EXIT__0") {
            return DockerProbeResult(
                availability: .available(sudo: true),
                runtime: elevatedRuntime
            )
        }

        let diagnostic = direct.lowercased()
        if diagnostic.contains("cannot connect")
            || diagnostic.contains("daemon running")
            || diagnostic.contains("docker desktop running") {
            return DockerProbeResult(availability: .daemonNotRunning, runtime: nil)
        }
        if diagnostic.contains("permission denied")
            || diagnostic.contains("operation not permitted") {
            return DockerProbeResult(availability: .permissionDenied, runtime: nil)
        }
        return DockerProbeResult(availability: .permissionDenied, runtime: nil)
    }

    private static func discoveryCommand(executableCandidates: [String]) -> String {
        let composeCandidates = executableCandidates.map { candidate in
            URL(fileURLWithPath: candidate)
                .deletingLastPathComponent()
                .appendingPathComponent("docker-compose")
                .path
        }
        let quoted = executableCandidates.map(ShellArgument.quote).joined(separator: " ")
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

    private static func parseDiscoveredExecutable(_ output: String) -> String? {
        output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix(composeV1Marker) }
    }

    private static func parseDiscoveredComposeV1Executable(_ output: String) -> String? {
        output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(composeV1Marker) }
            .map { String($0.dropFirst(composeV1Marker.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
