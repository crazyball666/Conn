import ConnKit
import ConnMonitor
import ConnOps
import ConnSSH
import Foundation
import Testing
@testable import ConnSSHCitadel

/// 真实 macOS 主机的 SSH 能力验收。
///
/// 默认跳过；只有显式提供 `CONN_MAC_SSH_HOST`、`CONN_MAC_SSH_USER`，并提供
/// `CONN_MAC_SSH_PASSWORD` 或 `CONN_MAC_SSH_KEY_PATH` 时才运行。测试只执行只读命令。
@Suite(.enabled(
    if: macHostConfiguration != nil,
    "Set CONN_MAC_SSH_HOST, CONN_MAC_SSH_USER and password or key path to run"
))
struct MacHostIntegrationTests {
    private var configuration: MacHostConfiguration {
        // Suite trait 保证缺少配置时不会执行测试体。
        macHostConfiguration!
    }

    private func withSession<Result>(
        _ body: (any SSHSession) async throws -> Result
    ) async throws -> Result {
        let configuration = self.configuration
        let session = try await CitadelTransport(hostKeyStore: InMemoryHostKeyStore()).connect(
            SSHEndpoint(host: configuration.host, port: configuration.port),
            username: configuration.username,
            auth: try configuration.auth(),
            hostKeyPolicy: .tofu
        )
        do {
            let result = try await body(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    @Test("平台画像识别为 macOS")
    func platformDetection() async throws {
        let profile = try await withSession {
            try await RemotePlatformDetector().detect(on: $0)
        }

        #expect(profile.kind == .macOS)
        #expect(profile.release?.isEmpty == false)
        #expect(profile.architecture?.isEmpty == false)
    }

    @Test("连续采集两次 Darwin 主机指标")
    func metricsCollection() async throws {
        let configuration = self.configuration
        let host = ConnKit.Host(
            name: "macOS integration host",
            address: configuration.host,
            username: configuration.username,
            port: configuration.port,
            authKind: configuration.authKind
        )
        let profile = RemotePlatformProfile(kind: .macOS)
        let collector = MetricCollector()

        let samples = try await withSession { session in
            let first = try await collector.collect(host: host, session: session, profile: profile)
            let second = try await collector.collect(host: host, session: session, profile: profile)
            return (first, second)
        }

        #expect(samples.0.platformProfile.kind == RemotePlatformKind.macOS)
        #expect(samples.1.platformProfile.kind == RemotePlatformKind.macOS)
        #expect(samples.1.cpu != nil)
        #expect(samples.1.memTotalBytes != nil)
        #expect(samples.1.diskTotalBytes != nil)
        #expect(samples.1.uptimeSeconds != nil)
    }

    @Test("Darwin 进程采集返回数据")
    func processCollection() async throws {
        let result = try await withSession {
            try await ProcessCollector().collect(
                session: $0,
                profile: RemotePlatformProfile(kind: .macOS)
            )
        }

        #expect(!result.processes.isEmpty)
        #expect(result.capabilityState.isSupportedOrDegraded)
    }

    @Test("发现 macOS Unified Log")
    func logDiscovery() async throws {
        let provider = try #require(LogProviderRegistry.provider(for: .macOS))
        let result = try await withSession {
            try await $0.exec(provider.discoveryCommand)
        }
        let sources = provider.parseDiscovery(result.stdoutText)

        #expect(result.isSuccess)
        #expect(sources.contains { $0.id == "darwin-unified" })
        #expect(provider.capabilityState(for: result.stdoutText).isSupportedOrDegraded)
    }

    @Test("Docker 探测在 macOS 上返回明确状态")
    func dockerProbe() async throws {
        let result = try await withSession {
            try await DockerService.probe(
                on: $0,
                profile: RemotePlatformProfile(kind: .macOS)
            )
        }

        #expect(result.availability != .unsupportedPlatform)
        if configuration.expectDocker {
            #expect(result.availability.isUsable)
            let runtime = try #require(result.runtime)
            if let expectedPath = configuration.expectedDockerPath {
                #expect(runtime.executable == expectedPath)
            }
            return
        }
        if result.availability.isUsable {
            #expect(result.runtime?.executable.isEmpty == false)
        } else {
            #expect(result.runtime == nil)
        }
    }
}

private struct MacHostConfiguration: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let keyPath: String?
    let keyKind: SSHKey.Kind
    let expectDocker: Bool
    let expectedDockerPath: String?

    var authKind: ConnKit.Host.AuthKind { password == nil ? .key : .password }

    func auth() throws -> SSHAuth {
        if let password {
            return .password(password)
        }
        guard let keyPath else {
            throw MacHostConfigurationError.missingAuthentication
        }
        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
        return .key(SSHPrivateKeyMaterial(kind: keyKind, pem: pem))
    }

    static func load(from environment: [String: String]) -> MacHostConfiguration? {
        guard let host = environment.nonEmptyValue(for: "CONN_MAC_SSH_HOST"),
              let username = environment.nonEmptyValue(for: "CONN_MAC_SSH_USER")
        else { return nil }

        let password = environment.nonEmptyValue(for: "CONN_MAC_SSH_PASSWORD")
        let keyPath = environment.nonEmptyValue(for: "CONN_MAC_SSH_KEY_PATH")
        guard password != nil || keyPath != nil else { return nil }

        let port = environment["CONN_MAC_SSH_PORT"].flatMap(Int.init) ?? 22
        let keyKind = environment["CONN_MAC_SSH_KEY_KIND"]
            .flatMap(SSHKey.Kind.init(rawValue:)) ?? .ed25519
        let expectedDockerPath = environment.nonEmptyValue(for: "CONN_MAC_SSH_EXPECT_DOCKER_PATH")
        let expectDocker = expectedDockerPath != nil
            || environment.boolValue(for: "CONN_MAC_SSH_EXPECT_DOCKER")
        return MacHostConfiguration(
            host: host,
            port: port,
            username: username,
            password: password,
            keyPath: keyPath,
            keyKind: keyKind,
            expectDocker: expectDocker,
            expectedDockerPath: expectedDockerPath
        )
    }
}

private enum MacHostConfigurationError: Error {
    case missingAuthentication
}

private let macHostConfiguration = MacHostConfiguration.load(
    from: ProcessInfo.processInfo.environment
)

private extension Dictionary where Key == String, Value == String {
    func nonEmptyValue(for key: String) -> String? {
        self[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    func boolValue(for key: String) -> Bool {
        guard let value = self[key]?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }
}

private extension CapabilityState {
    var isSupportedOrDegraded: Bool {
        switch self {
        case .supported, .degraded:
            true
        case .unavailable, .unsupported:
            false
        }
    }
}
