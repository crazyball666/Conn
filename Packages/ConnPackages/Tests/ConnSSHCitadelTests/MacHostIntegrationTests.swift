import ConnKit
import ConnMultiplexer
import ConnMonitor
import ConnOps
@testable import ConnSSH
import Foundation
import Testing
@testable import ConnSSHCitadel

private enum BoundedAcceptanceOperationError: Error, Equatable {
    case timedOut
    case cleanupTimedOut
}

private enum AcceptancePrimaryOutcome<Value: Sendable>: @unchecked Sendable {
    case success(Value)
    case failure(any Error)
    case timedOut
    case cancelled
}

private enum AcceptanceCleanupOutcome: Sendable {
    case finished
    case timedOut
}

private actor AcceptanceOneShot<Outcome: Sendable> {
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private actor BoundedAcceptanceCleanup {
    private let action: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    func start() -> Task<Void, Never> {
        if let task { return task }
        let action = self.action
        // Cleanup must not inherit cancellation from the timed-out/cancelled caller.
        let task = Task.detached { await action() }
        self.task = task
        return task
    }
}

private actor AcceptanceSessionCloseOwner {
    private let action: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    func close() async {
        await start().value
    }

    func close(timeout: Duration) async -> Bool {
        await waitForAcceptanceTask(start(), timeout: timeout)
    }

    private func start() -> Task<Void, Never> {
        if let task { return task }
        let action = self.action
        let task = Task.detached { await action() }
        self.task = task
        return task
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
        // A subsystem can finish opening while parent-session teardown is already in flight.
        // Close it immediately on a best-effort basis. This late close may overlap the parent
        // close; strict LIFO is impossible because the parent close is what unblocks the open.
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
    cleanupTimeout: Duration,
    cleanup: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let cleanup = BoundedAcceptanceCleanup(action: cleanup)
    let primary = AcceptanceOneShot<AcceptancePrimaryOutcome<Result>>()
    // These tasks are intentionally unstructured: helper return must never join work that
    // ignores cancellation. Real session close should unblock Citadel; a pathological detached
    // task that ignores both cancellation and cleanup can only be reclaimed at process exit.
    let operationTask = Task.detached {
        do {
            await primary.resolve(.success(try await operation()))
        } catch {
            await primary.resolve(.failure(error))
        }
    }
    let timeoutTask = Task.detached {
        do {
            try await Task.sleep(for: timeout)
            await primary.resolve(.timedOut)
        } catch {
            // Losing timer cancellation is expected.
        }
    }

    let outcome = await withTaskCancellationHandler {
        await primary.wait()
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        _ = Task.detached { await primary.resolve(.cancelled) }
    }
    operationTask.cancel()
    timeoutTask.cancel()

    guard await runBoundedAcceptanceCleanup(cleanup, timeout: cleanupTimeout) else {
        // The detached cleanup task was cancelled but may survive if it also ignores cancellation.
        throw BoundedAcceptanceOperationError.cleanupTimedOut
    }
    try Task.checkCancellation()

    switch outcome {
    case let .success(result):
        return result
    case let .failure(error):
        throw error
    case .timedOut:
        throw BoundedAcceptanceOperationError.timedOut
    case .cancelled:
        throw CancellationError()
    }
}

private func runBoundedAcceptanceCleanup(
    _ cleanup: BoundedAcceptanceCleanup,
    timeout: Duration
) async -> Bool {
    let cleanupTask = await cleanup.start()
    return await waitForAcceptanceTask(cleanupTask, timeout: timeout)
}

private func waitForAcceptanceTask(
    _ task: Task<Void, Never>,
    timeout: Duration
) async -> Bool {
    let completion = AcceptanceOneShot<AcceptanceCleanupOutcome>()
    let observerTask = Task.detached {
        await task.value
        await completion.resolve(.finished)
    }
    let timeoutTask = Task.detached {
        do {
            try await Task.sleep(for: timeout)
            await completion.resolve(.timedOut)
        } catch {
            // Losing timer cancellation is expected.
        }
    }

    let outcome = await completion.wait()
    observerTask.cancel()
    timeoutTask.cancel()
    if case .timedOut = outcome {
        task.cancel()
        return false
    }
    return true
}

@Suite("macOS acceptance bounded operation — cleanup")
struct MacHostBoundedOperationTests {
    @Test("success awaits async cleanup exactly once")
    func successAwaitsCleanup() async throws {
        let probe = BoundedOperationProbe()

        let value = try await withBoundedAcceptanceOperation(
            timeout: .seconds(1),
            cleanupTimeout: .seconds(1),
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
                cleanupTimeout: .seconds(1),
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
                cleanupTimeout: .seconds(1),
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
                cleanupTimeout: .seconds(1),
                cleanup: { await probe.cleanup() }
            ) {
                await probe.waitUntilCleanup()
                return "unblocked"
            }
        }
        do {
            try await probe.waitUntilOperationBlocked(timeout: .seconds(1))
        } catch {
            operation.cancel()
            _ = await operation.result
            throw error
        }

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

    @Test("hanging cleanup returns a distinct error within its secondary deadline")
    func hangingCleanupIsBounded() async throws {
        let probe = DetachedWorkProbe()
        let failSafe = Task {
            try? await Task.sleep(for: .seconds(2))
            await probe.releaseCleanup()
        }
        let started = ContinuousClock.now

        do {
            _ = try await withBoundedAcceptanceOperation(
                timeout: .seconds(1),
                cleanupTimeout: .milliseconds(50),
                cleanup: { await probe.waitForCleanupRelease() }
            ) {
                "done"
            }
            Issue.record("Expected cleanup timeout")
        } catch let error as BoundedAcceptanceOperationError {
            #expect(error == .cleanupTimedOut)
        }

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await probe.cleanupCount == 1)
        await probe.releaseCleanup()
        failSafe.cancel()
        await failSafe.value
    }

    @Test("operation ignoring cancellation and cleanup cannot delay timeout return")
    func uncooperativeOperationDoesNotDelayTimeout() async throws {
        let probe = DetachedWorkProbe()
        let failSafe = Task {
            try? await Task.sleep(for: .seconds(2))
            await probe.releaseOperation()
        }
        let operation = Task {
            try await withBoundedAcceptanceOperation(
                timeout: .milliseconds(50),
                cleanupTimeout: .milliseconds(100),
                cleanup: { await probe.recordCleanup() }
            ) {
                await probe.waitForOperationRelease()
                return "released"
            }
        }
        do {
            try await probe.waitUntilOperationStarts(timeout: .seconds(1))
        } catch {
            await probe.releaseOperation()
            failSafe.cancel()
            _ = await operation.result
            throw error
        }
        let started = ContinuousClock.now

        do {
            _ = try await operation.value
            Issue.record("Expected operation timeout")
        } catch let error as BoundedAcceptanceOperationError {
            #expect(error == .timedOut)
        }

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await probe.cleanupCount == 1)
        await probe.releaseOperation()
        failSafe.cancel()
        await failSafe.value
    }

    @Test("session close owner memoizes one close task")
    func sessionCloseOwnerClosesExactlyOnce() async {
        let probe = SessionCloseProbe()
        let owner = AcceptanceSessionCloseOwner {
            await probe.closeSession()
        }

        async let first: Void = owner.close()
        async let second: Void = owner.close()
        _ = await (first, second)
        await owner.close()

        #expect(await probe.closeCount == 1)
    }

    @Test("pre-registered resources close in strict LIFO order")
    func preRegisteredResourcesCloseBeforeSession() async {
        let probe = CleanupStackProbe()
        let cleanup = AcceptanceCleanupStack(actions: [
            { await probe.record("session-close") },
        ])
        await cleanup.register { await probe.record("resource-close") }

        await cleanup.closeAll()

        #expect(await probe.events == ["resource-close", "session-close"])
    }

    @Test("late resource closes during parent close and cleanup waits safely")
    func lateResourceRegistrationIsCleanedUp() async throws {
        let probe = CleanupStackProbe()
        let cleanup = AcceptanceCleanupStack(actions: [
            { await probe.closeSession() },
        ])
        let failSafe = Task {
            try? await Task.sleep(for: .seconds(2))
            await probe.finishSessionCleanup()
        }
        let helper = Task {
            try await withBoundedAcceptanceOperation(
                timeout: .milliseconds(50),
                cleanupTimeout: .seconds(1),
                cleanup: { await cleanup.closeAll() }
            ) {
                // Models Citadel open ignoring cancellation until parent session close starts.
                await probe.waitForSessionCleanupToStart()
                await cleanup.register { await probe.record("resource-close") }
                return "late-open"
            }
        }
        do {
            try await probe.waitUntilSessionCleanupStarts(timeout: .seconds(1))
            try await probe.waitUntilEventCount(2, timeout: .seconds(1))
        } catch {
            await probe.finishSessionCleanup()
            _ = await helper.result
            failSafe.cancel()
            await failSafe.value
            throw error
        }

        #expect(await probe.events == ["session-start", "resource-close"])
        await probe.finishSessionCleanup()
        do {
            _ = try await helper.value
            Issue.record("Expected operation timeout")
        } catch let error as BoundedAcceptanceOperationError {
            #expect(error == .timedOut)
        }
        failSafe.cancel()
        await failSafe.value
        #expect(await probe.events == ["session-start", "resource-close", "session-finish"])
    }
}

@Suite("macOS SSH acceptance configuration")
struct MacHostConfigurationTests {
    @Test("missing fingerprint disables real-host acceptance")
    func missingFingerprintDisablesConfiguration() {
        let configuration = MacHostConfiguration.load(from: [
            "CONN_MAC_SSH_HOST": "mac.example.test",
            "CONN_MAC_SSH_USER": "tester",
            "CONN_MAC_SSH_PASSWORD": "synthetic-password",
        ])

        #expect(configuration == nil)
    }

    @Test("configured fingerprint produces strict host-key policy")
    func fingerprintProducesStrictPolicy() throws {
        let fingerprint = "SHA256:synthetic-test-fingerprint"
        let configuration = try #require(MacHostConfiguration.load(from: [
            "CONN_MAC_SSH_HOST": "mac.example.test",
            "CONN_MAC_SSH_USER": "tester",
            "CONN_MAC_SSH_PASSWORD": "synthetic-password",
            "CONN_MAC_SSH_FINGERPRINT": fingerprint,
        ]))

        #expect(configuration.hostKeyPolicy == .strict(expectedFingerprint: fingerprint))
    }
}

/// 真实 macOS 主机的 SSH 能力验收。
///
/// 默认跳过；只有显式提供 `CONN_MAC_SSH_HOST`、`CONN_MAC_SSH_USER`、
/// `CONN_MAC_SSH_FINGERPRINT`，并提供 `CONN_MAC_SSH_PASSWORD` 或
/// `CONN_MAC_SSH_KEY_PATH` 时才运行。测试只执行只读命令。
@Suite(.enabled(
    if: macHostConfiguration != nil,
    "Set CONN_MAC_SSH_HOST, CONN_MAC_SSH_USER, CONN_MAC_SSH_FINGERPRINT and password or key path to run"
))
struct MacHostIntegrationTests {
    private var configuration: MacHostConfiguration {
        // Suite trait 保证缺少配置时不会执行测试体。
        macHostConfiguration!
    }

    private func withSession<Value>(
        _ body: (any SSHSession, AcceptanceSessionCloseOwner) async throws -> Value
    ) async throws -> Value {
        let configuration = self.configuration
        let session = try await CitadelTransport(hostKeyStore: InMemoryHostKeyStore()).connect(
            SSHEndpoint(host: configuration.host, port: configuration.port),
            username: configuration.username,
            auth: try configuration.auth(),
            hostKeyPolicy: configuration.hostKeyPolicy
        )
        let sessionClose = AcceptanceSessionCloseOwner {
            await session.close()
        }
        let bodyResult: Result<Value, any Error>
        do {
            bodyResult = .success(try await body(session, sessionClose))
        } catch {
            bodyResult = .failure(error)
        }
        guard await sessionClose.close(timeout: .seconds(5)) else {
            throw BoundedAcceptanceOperationError.cleanupTimedOut
        }
        return try bodyResult.get()
    }

    @Test("平台画像识别为 macOS")
    func platformDetection() async throws {
        let profile = try await withSession { session, _ in
            try await RemotePlatformDetector().detect(on: session)
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

        let samples = try await withSession { session, _ in
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
        let result = try await withSession { session, _ in
            try await ProcessCollector().collect(
                session: session,
                profile: RemotePlatformProfile(kind: .macOS)
            )
        }

        #expect(!result.processes.isEmpty)
        #expect(result.capabilityState.isSupportedOrDegraded)
    }

    @Test("发现 macOS Unified Log")
    func logDiscovery() async throws {
        let provider = try #require(LogProviderRegistry.provider(for: .macOS))
        let result = try await withSession { session, _ in
            try await session.exec(provider.discoveryCommand)
        }
        let sources = provider.parseDiscovery(result.stdoutText)

        #expect(result.isSuccess)
        #expect(sources.contains { $0.id == "darwin-unified" })
        #expect(provider.capabilityState(for: result.stdoutText).isSupportedOrDegraded)
    }

    @Test("SFTP 只读解析并列出当前目录")
    func readOnlySFTPAcceptance() async throws {
        let resolvedPath = try await withSession { session, sessionClose in
            let cleanup = AcceptanceCleanupStack(actions: [
                { await sessionClose.close() },
            ])
            return try await withBoundedAcceptanceOperation(
                timeout: .seconds(30),
                cleanupTimeout: .seconds(5),
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
        let sentinelObserved = try await withSession { session, sessionClose in
            let cleanup = AcceptanceCleanupStack(actions: [
                { await sessionClose.close() },
            ])
            return try await withBoundedAcceptanceOperation(
                timeout: .seconds(30),
                cleanupTimeout: .seconds(5),
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
        let output = try await withSession { session, sessionClose in
            let cleanup = AcceptanceCleanupStack(actions: [
                { await sessionClose.close() },
            ])
            return try await withBoundedAcceptanceOperation(
                timeout: .seconds(30),
                cleanupTimeout: .seconds(5),
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
        let result = try await withSession { session, _ in
            try await DockerService.probe(
                on: session,
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

/// 真实 macOS 主机上的 tmux provider 端到端验收。
///
/// 该套件默认跳过。除了 SSH 配置外，还要求显式设置
/// `CONN_MAC_TMUX_ACCEPTANCE=1` 和 `CONN_MAC_TMUX_ALLOW_MUTATION=1`，因为它会在远端
/// 创建、重命名并销毁一个带随机名的 Session。它验证的是产品真实路径：provider probe →
/// workspace lifecycle → descriptor → PTY attach → Control Mode catalog → cleanup。
@Suite(.enabled(
    if: macHostConfiguration != nil
        && ProcessInfo.processInfo.environment.boolValue(for: "CONN_MAC_TMUX_ACCEPTANCE")
        && ProcessInfo.processInfo.environment.boolValue(for: "CONN_MAC_TMUX_ALLOW_MUTATION"),
    "Set macOS SSH credentials, CONN_MAC_TMUX_ACCEPTANCE=1 and CONN_MAC_TMUX_ALLOW_MUTATION=1 to run"
))
struct MacHostTmuxIntegrationTests {
    private var configuration: MacHostConfiguration { macHostConfiguration! }

    @Test("macOS tmux provider 完成 probe、生命周期与 PTY Attach")
    func providerLifecycleAndAttachment() async throws {
        try await withPersistentContext { context in
            let provider = TmuxProvider()
            let availability = try await provider.probe(in: context)
            #expect(availability.state == .available || availability.state == .degraded)

            let name = "conn-accept-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
            var workspace: RemoteWorkspaceRef?
            var attachment: (any PersistentTerminalAttachment)?
            var catalog: (any PersistentTerminalCatalogAttachment)?
            do {
                let created = try await provider.createWorkspace(
                    CreateWorkspaceRequest(name: name),
                    in: context
                )
                workspace = created

                let listed = try await provider.listWorkspaces(in: context)
                #expect(listed.contains { $0.workspace.workspaceID == created.workspaceID })

                let renamedName = "\(name)-renamed"
                try await provider.renameWorkspace(created, to: renamedName, in: context)
                let renamed = try await provider.listWorkspaces(in: context)
                #expect(renamed.contains {
                    $0.workspace.workspaceID == created.workspaceID && $0.name == renamedName
                })

                let descriptor = try provider.makeAttachmentDescriptor(to: created, in: context)
                let openedAttachment = try await provider.openAttachment(
                    descriptor,
                    reason: .initial,
                    terminalSize: .init(cols: 80, rows: 24),
                    in: context
                )
                attachment = openedAttachment
                guard case let .byteTerminal(channel) = openedAttachment.presentation else {
                    Issue.record("tmux acceptance attachment did not expose a byte terminal")
                    await openedAttachment.close()
                    attachment = nil
                    throw TmuxAcceptanceError.invalidAttachment
                }
                let sentinel = "__CONN_TMUX_E2E_ACCEPTED__"
                try await channel.write(Data("printf '\\n\(sentinel)\\n'\n".utf8))
                let output = try await withTmuxTimeout(.seconds(20)) {
                    try await readTmuxUntil(channel: channel, sentinel: sentinel)
                }
                #expect(output.contains(sentinel))
                await openedAttachment.close()
                attachment = nil

                let openedCatalog = try await provider.openCatalog(in: context)
                catalog = openedCatalog
                var iterator = openedCatalog.snapshots.makeAsyncIterator()
                let snapshot = try #require(await iterator.next())
                #expect(snapshot.freshness == .liveSubscription(observedAt: snapshot.observedAt))
                if let tmuxCatalog = openedCatalog as? any TmuxWorkspaceCatalogManaging {
                    // Optional flags vary by tmux release. The acceptance only requires that
                    // the facet exposes the negotiated result instead of assuming a version.
                    _ = tmuxCatalog.controlCapabilities
                    _ = tmuxCatalog.controlConfiguration
                } else {
                    Issue.record("tmux provider did not expose its management facet")
                }
                await openedCatalog.close()
                catalog = nil

                try await provider.destroyWorkspace(created, in: context)
                workspace = nil
            } catch {
                await catalog?.close()
                await attachment?.close()
                if let workspace {
                    try? await provider.destroyWorkspace(workspace, in: context)
                }
                throw error
            }
        }
    }

    private func withPersistentContext<Value: Sendable>(
        _ body: (PersistentTerminalContext) async throws -> Value
    ) async throws -> Value {
        let configuration = self.configuration
        let session = try await CitadelTransport(hostKeyStore: InMemoryHostKeyStore()).connect(
            SSHEndpoint(host: configuration.host, port: configuration.port),
            username: configuration.username,
            auth: try configuration.auth(),
            hostKeyPolicy: configuration.hostKeyPolicy
        )
        let sessionClose = AcceptanceSessionCloseOwner { await session.close() }
        let host = ConnKit.Host(
            id: "tmux-mac-acceptance",
            name: "tmux macOS acceptance",
            address: configuration.host,
            username: configuration.username,
            port: configuration.port,
            authKind: configuration.authKind
        )
        let platform = try await RemotePlatformDetector().detect(on: session)
        let platformContext = RemotePlatformContext(
            connectionIdentity: SSHConnectionIdentity(host: host),
            session: session,
            profile: platform
        )
        let providerConfiguration = try JSONEncoder().encode(TmuxProviderConfiguration())
        let profile = TerminalBackendProfile(
            id: "tmux-mac-acceptance-profile",
            hostID: host.id,
            providerID: TmuxProvider.providerID,
            providerConfigurationKey: "default",
            displayName: "tmux acceptance",
            configurationJSON: String(decoding: providerConfiguration, as: UTF8.self)
        )
        let context = try PersistentTerminalContext(
            platformContext: platformContext,
            backendProfile: profile
        )
        let result: Result<Value, any Error>
        do {
            result = .success(try await body(context))
        } catch {
            result = .failure(error)
        }
        guard await sessionClose.close(timeout: .seconds(5)) else {
            throw BoundedAcceptanceOperationError.cleanupTimedOut
        }
        return try result.get()
    }
}

private enum TmuxAcceptanceError: Error {
    case timeout
    case invalidAttachment
}

private func withTmuxTimeout<Value: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TmuxAcceptanceError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func readTmuxUntil(
    channel: any ShellChannel,
    sentinel: String
) async throws -> String {
    var output = Data()
    var iterator = channel.output.makeAsyncIterator()
    while let chunk = try await iterator.next() {
        output.append(chunk)
        let text = String(decoding: output, as: UTF8.self)
        if text.contains(sentinel) { return text }
    }
    return String(decoding: output, as: UTF8.self)
}

private struct MacHostConfiguration: Sendable {
    let host: String
    let port: Int
    let username: String
    let fingerprint: String
    let password: String?
    let keyPath: String?
    let keyKind: SSHKey.Kind
    let expectDocker: Bool
    let expectedDockerPath: String?

    var authKind: ConnKit.Host.AuthKind { password == nil ? .key : .password }
    var hostKeyPolicy: HostKeyPolicy { .strict(expectedFingerprint: fingerprint) }

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
              let username = environment.nonEmptyValue(for: "CONN_MAC_SSH_USER"),
              let fingerprint = environment.nonEmptyValue(for: "CONN_MAC_SSH_FINGERPRINT")
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
            fingerprint: fingerprint,
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
    case readinessTimedOut
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

    func waitUntilOperationBlocked(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !operationBlocked {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BoundedOperationProbeError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
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

private actor DetachedWorkProbe {
    private(set) var cleanupCount = 0
    private var operationStarted = false
    private var operationReleased = false
    private var cleanupReleased = false
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var cleanupContinuation: CheckedContinuation<Void, Never>?

    func waitForOperationRelease() async {
        operationStarted = true
        guard !operationReleased else { return }
        await withCheckedContinuation { operationContinuation = $0 }
    }

    func waitUntilOperationStarts(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !operationStarted {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BoundedOperationProbeError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseOperation() {
        operationReleased = true
        operationContinuation?.resume()
        operationContinuation = nil
    }

    func waitForCleanupRelease() async {
        cleanupCount += 1
        guard !cleanupReleased else { return }
        await withCheckedContinuation { cleanupContinuation = $0 }
    }

    func recordCleanup() {
        cleanupCount += 1
    }

    func releaseCleanup() {
        cleanupReleased = true
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }
}

private actor CleanupStackProbe {
    private(set) var events: [String] = []
    private var sessionCleanupStarted = false
    private var sessionStartContinuation: CheckedContinuation<Void, Never>?
    private var sessionCleanupContinuation: CheckedContinuation<Void, Never>?

    func closeSession() async {
        sessionCleanupStarted = true
        events.append("session-start")
        sessionStartContinuation?.resume()
        sessionStartContinuation = nil
        await withCheckedContinuation { sessionCleanupContinuation = $0 }
        events.append("session-finish")
    }

    func waitForSessionCleanupToStart() async {
        guard !sessionCleanupStarted else { return }
        await withCheckedContinuation { sessionStartContinuation = $0 }
    }

    func waitUntilSessionCleanupStarts(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !sessionCleanupStarted {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BoundedOperationProbeError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilEventCount(_ count: Int, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while events.count < count {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BoundedOperationProbeError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func record(_ event: String) {
        events.append(event)
    }

    func finishSessionCleanup() {
        sessionCleanupStarted = true
        sessionStartContinuation?.resume()
        sessionStartContinuation = nil
        sessionCleanupContinuation?.resume()
        sessionCleanupContinuation = nil
    }
}

private actor SessionCloseProbe {
    private(set) var closeCount = 0

    func closeSession() async {
        closeCount += 1
        try? await Task.sleep(for: .milliseconds(20))
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
