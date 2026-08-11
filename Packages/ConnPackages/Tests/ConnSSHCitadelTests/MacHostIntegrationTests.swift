import ConnKit
import ConnMonitor
import ConnOps
import ConnSSH
import Foundation
import Testing
@testable import ConnSSHCitadel

private enum BoundedAcceptanceOperationError: Error, Equatable {
    case timedOut
}

private actor BoundedAcceptanceCleanup {
    private let action: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    func run() async {
        let task: Task<Void, Never>
        if let existing = self.task {
            task = existing
        } else {
            let action = self.action
            // Cleanup must not inherit cancellation from the timed-out/cancelled caller.
            let created = Task.detached { await action() }
            self.task = created
            task = created
        }
        await task.value
    }
}

private typealias AcceptanceCleanupAction = @Sendable () async -> Void

private actor AcceptanceCleanupStack {
    private var actions: [AcceptanceCleanupAction]
    private var task: Task<Void, Never>?

    init(actions: [AcceptanceCleanupAction] = []) {
        self.actions = actions
    }

    func register(_ action: @escaping AcceptanceCleanupAction) async {
        guard task != nil else {
            actions.append(action)
            return
        }
        // A subsystem can finish opening while session teardown is already in flight.
        await Task.detached { await action() }.value
    }

    func closeAll() async {
        let task: Task<Void, Never>
        if let existing = self.task {
            task = existing
        } else {
            // Resources are registered after the session, so LIFO closes them first.
            let actions = Array(self.actions.reversed())
            self.actions.removeAll()
            let created = Task.detached {
                for action in actions {
                    await action()
                }
            }
            self.task = created
            task = created
        }
        await task.value
    }
}

private func withBoundedAcceptanceOperation<Result: Sendable>(
    timeout: Duration,
    cleanup: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let cleanup = BoundedAcceptanceCleanup(action: cleanup)
    return try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BoundedAcceptanceOperationError.timedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw BoundedAcceptanceOperationError.timedOut
                }
                group.cancelAll()
                // Closing the subsystem/session is what unblocks non-cooperative Citadel awaits.
                await cleanup.run()
                try Task.checkCancellation()
                return result
            } catch {
                group.cancelAll()
                await cleanup.run()
                try Task.checkCancellation()
                throw error
            }
        }
    } onCancel: {
        // The handler is synchronous; start the same exactly-once async cleanup independently.
        _ = Task.detached { await cleanup.run() }
    }
}

@Suite("macOS acceptance bounded operation — cleanup")
struct MacHostBoundedOperationTests {
    @Test("success awaits async cleanup exactly once")
    func successAwaitsCleanup() async throws {
        let probe = BoundedOperationProbe()

        let value = try await withBoundedAcceptanceOperation(
            timeout: .seconds(1),
            cleanup: { await probe.cleanup() }
        ) {
            "done"
        }

        #expect(value == "done")
        #expect(await probe.cleanupCount == 1)
        #expect(await probe.cleanupFinished)
    }

    @Test("operation error awaits async cleanup before propagating")
    func errorAwaitsCleanup() async throws {
        let probe = BoundedOperationProbe()

        do {
            let _: String = try await withBoundedAcceptanceOperation(
                timeout: .seconds(1),
                cleanup: { await probe.cleanup() }
            ) {
                throw BoundedOperationProbeError.operationFailed
            }
            Issue.record("Expected operation failure")
        } catch let error as BoundedOperationProbeError {
            #expect(error == .operationFailed)
        }

        #expect(await probe.cleanupCount == 1)
        #expect(await probe.cleanupFinished)
    }

    @Test("timeout cleans up before throwing and unblocks cancellation-ignoring work")
    func timeoutCleansUpAndUnblocksWork() async throws {
        let probe = BoundedOperationProbe()

        do {
            _ = try await withBoundedAcceptanceOperation(
                timeout: .milliseconds(50),
                cleanup: { await probe.cleanup() }
            ) {
                await probe.waitUntilCleanup()
                return "unblocked"
            }
            Issue.record("Expected bounded operation timeout")
        } catch let error as BoundedAcceptanceOperationError {
            #expect(error == .timedOut)
        }

        #expect(await probe.cleanupCount == 1)
        #expect(await probe.cleanupFinished)
    }

    @Test("parent cancellation triggers cleanup and reports cancellation")
    func cancellationCleansUpAndUnblocksWork() async throws {
        let probe = BoundedOperationProbe()
        let operation = Task {
            try await withBoundedAcceptanceOperation(
                timeout: .seconds(30),
                cleanup: { await probe.cleanup() }
            ) {
                await probe.waitUntilCleanup()
                return "unblocked"
            }
        }
        await probe.waitUntilOperationBlocked()

        operation.cancel()

        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await probe.cleanupCount == 1)
        #expect(await probe.cleanupFinished)
    }

    @Test("resource registered after cleanup starts is closed immediately")
    func lateResourceRegistrationIsCleanedUp() async {
        let probe = CleanupStackProbe()
        let cleanup = AcceptanceCleanupStack(actions: [
            { await probe.closeSession() },
        ])
        let cleanupTask = Task { await cleanup.closeAll() }
        await probe.waitUntilSessionCleanupStarts()

        await cleanup.register { await probe.closeResource() }

        #expect(await probe.resourceCleanupCount == 1)
        await probe.finishSessionCleanup()
        await cleanupTask.value
    }
}

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

    @Test("SFTP 只读解析并列出当前目录")
    func readOnlySFTPAcceptance() async throws {
        let resolvedPath = try await withSession { session in
            let cleanup = AcceptanceCleanupStack(actions: [
                { await session.close() },
            ])
            return try await withBoundedAcceptanceOperation(
                timeout: .seconds(30),
                cleanup: { await cleanup.closeAll() }
            ) {
                let fileSystem = try await session.sftp()
                await cleanup.register { await fileSystem.close() }
                let path = try await fileSystem.realPath(".")
                _ = try await fileSystem.list(path)
                return path
            }
        }

        #expect(!resolvedPath.isEmpty)
    }

    @Test("80x24 PTY 执行 printf 并收到哨兵")
    func ptyAcceptance() async throws {
        let sentinel = "__CONN_MAC_PTY_ACCEPTED__"
        let command = "printf '\\137\\137CONN_MAC_PTY_ACCEPTED\\137\\137\\n'; exit\n"
        let sentinelObserved = try await withSession { session in
            let cleanup = AcceptanceCleanupStack(actions: [
                { await session.close() },
            ])
            return try await withBoundedAcceptanceOperation(
                timeout: .seconds(30),
                cleanup: { await cleanup.closeAll() }
            ) {
                let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))
                await cleanup.register { await channel.close() }
                try await channel.write(Data(command.utf8))

                var output = Data()
                for try await chunk in channel.output {
                    output.append(chunk)
                    if String(decoding: output, as: UTF8.self).contains(sentinel) {
                        return true
                    }
                }
                return false
            }
        }

        #expect(sentinelObserved)
    }

    @Test("有限 Unified Log 命令流读取到 EOF 与哨兵")
    func finiteLogStreamAcceptance() async throws {
        let sentinel = "__CONN_MAC_LOG_STREAM_ACCEPTED__"
        let command = "/usr/bin/log show --last 1m --style syslog 2>&1 | head -n 1; "
            + "printf '\\n\(sentinel)\\n'"
        let output = try await withSession { session in
            let cleanup = AcceptanceCleanupStack(actions: [
                { await session.close() },
            ])
            return try await withBoundedAcceptanceOperation(
                timeout: .seconds(30),
                cleanup: { await cleanup.closeAll() }
            ) {
                let stream = try await session.execStream(command)
                var output = Data()
                for try await chunk in stream {
                    output.append(chunk)
                }
                return String(decoding: output, as: UTF8.self)
            }
        }

        #expect(output.contains(sentinel))
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

private enum BoundedOperationProbeError: Error, Equatable {
    case operationFailed
}

private actor BoundedOperationProbe {
    private(set) var cleanupCount = 0
    private(set) var cleanupFinished = false
    private var operationBlocked = false
    private var cleanupStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilCleanup() async {
        operationBlocked = true
        guard !cleanupStarted else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilOperationBlocked() async {
        while !operationBlocked {
            await Task.yield()
        }
    }

    func cleanup() async {
        cleanupCount += 1
        try? await Task.sleep(for: .milliseconds(20))
        cleanupStarted = true
        cleanupFinished = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CleanupStackProbe {
    private(set) var resourceCleanupCount = 0
    private var sessionCleanupStarted = false
    private var sessionCleanupContinuation: CheckedContinuation<Void, Never>?

    func closeSession() async {
        sessionCleanupStarted = true
        await withCheckedContinuation { sessionCleanupContinuation = $0 }
    }

    func waitUntilSessionCleanupStarts() async {
        while !sessionCleanupStarted {
            await Task.yield()
        }
    }

    func closeResource() {
        resourceCleanupCount += 1
    }

    func finishSessionCleanup() {
        sessionCleanupContinuation?.resume()
        sessionCleanupContinuation = nil
    }
}

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
