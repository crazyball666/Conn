import ConnKit
import ConnSSH
import Foundation

/// 一个平台的 Docker CLI 发现与运行时可用性探测能力。
public protocol DockerEnvironmentProvider: Sendable {
    var platform: RemotePlatformKind { get }
    var scriptFamily: RemoteScriptFamily { get }
    func probe(on session: any SSHSession) async throws -> DockerProbeResult
}

public struct LinuxDockerEnvironmentProvider: DockerEnvironmentProvider {
    public let platform = RemotePlatformKind.linux
    public let scriptFamily = RemoteScriptFamily.posix

    public init() {}

    public func probe(on session: any SSHSession) async throws -> DockerProbeResult {
        try await POSIXDockerEnvironmentProbe.probe(on: session)
    }
}

public struct DarwinDockerEnvironmentProvider: DockerEnvironmentProvider {
    public let platform = RemotePlatformKind.macOS
    public let scriptFamily = RemoteScriptFamily.posix

    public init() {}

    public func probe(on session: any SSHSession) async throws -> DockerProbeResult {
        try await POSIXDockerEnvironmentProbe.probe(on: session)
    }
}

/// 按远端平台选择 Docker 环境 provider；可注入自定义 provider 供组合与测试。
public struct DockerEnvironmentProviderRegistry: Sendable {
    private struct Key: Sendable, Hashable {
        let platform: RemotePlatformKind
        let scriptFamily: RemoteScriptFamily
    }

    private let providers: [Key: any DockerEnvironmentProvider]

    public static let `default` = DockerEnvironmentProviderRegistry(providers: [
        LinuxDockerEnvironmentProvider(),
        DarwinDockerEnvironmentProvider(),
    ])

    public init(providers: [any DockerEnvironmentProvider]) {
        var indexed: [Key: any DockerEnvironmentProvider] = [:]
        for provider in providers {
            let key = Key(platform: provider.platform, scriptFamily: provider.scriptFamily)
            if indexed[key] == nil {
                indexed[key] = provider
            }
        }
        self.providers = indexed
    }

    public func provider(
        for platform: RemotePlatformKind,
        scriptFamily: RemoteScriptFamily
    ) -> (any DockerEnvironmentProvider)? {
        providers[Key(platform: platform, scriptFamily: scriptFamily)]
    }
}

private enum POSIXDockerEnvironmentProbe {
    static func probe(on session: any SSHSession) async throws -> DockerProbeResult {
        let executables = try await RemoteExecutableResolver.shared.resolve(
            ["docker", "docker-compose"],
            on: session
        )
        guard let executable = executables["docker"] else {
            return DockerProbeResult(availability: .notInstalled, runtime: nil)
        }
        let composeV1Executable = executables["docker-compose"]

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

}
