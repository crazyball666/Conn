import ConnKit
import ConnCrypto
import ConnSSH
import Foundation
import Testing
@testable import ConnPrivateNetwork

@Suite("私有网络运行时")
struct PrivateNetworkRegistryTests {
    @Test("旧租约关闭不停止后来启动的节点")
    func staleLeaseDoesNotCloseReplacementRuntime() async throws {
        let profiles = InMemoryProfiles(profile: PrivateNetworkProfile(id: "p", name: "Test", provider: .tailscale))
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory()
        let registry = PrivateNetworkRegistry(profileRepository: profiles, credentialStore: credentials, factory: factory)
        let first = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "host.example"))
        await registry.stop(profileID: "p")
        let next = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "host.example"))
        await first.close()
        #expect(await registry.status(profileID: "p") == .running)
        await next.close()
    }

    @Test("上一节点完成身份保存和关闭后才允许重启")
    func waitsForClosingRuntimeBeforeRestart() async throws {
        let profiles = InMemoryProfiles(profile: PrivateNetworkProfile(id: "p", name: "Test", provider: .tailscale))
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory(closeDelay: .milliseconds(100))
        let registry = PrivateNetworkRegistry(profileRepository: profiles, credentialStore: credentials, factory: factory, idleTimeout: .zero)
        let first = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "host.example"))
        let closing = Task { await first.close() }
        while !(await factory.isClosing) { await Task.yield() }
        let next = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "host.example"))
        #expect(await factory.madeWhileClosing == false)
        await closing.value
        await next.close()
    }

    @Test("无空闲宽限期时，租约全部关闭后立即停止")
    func sharesRuntimeAndStopsAfterLastLease() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory()
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .zero
        )

        let first = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        let second = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.2"))
        #expect(await factory.makeCount == 1)
        #expect(await registry.status(profileID: "p") == .running)

        await first.close()
        #expect(await registry.status(profileID: "p") == .running)
        await second.close()
        #expect(await registry.status(profileID: "p") == .stopped)
        #expect(await factory.closeCount == 1)
    }

    @Test("同一 profile 并发首次连接只启动一个 runtime")
    func concurrentFirstConnectionsShareRuntime() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory()
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .zero
        )

        async let first = registry.openProxy(
            profileID: "p",
            to: SSHEndpoint(host: "100.64.0.1")
        )
        async let second = registry.openProxy(
            profileID: "p",
            to: SSHEndpoint(host: "100.64.0.2")
        )
        let leases = try await [first, second]

        #expect(await factory.makeCount == 1)
        for lease in leases { await lease.close() }
        #expect(await factory.closeCount == 1)
    }

    @Test("空闲宽限期内保持活跃并在后续连接中复用节点")
    func idleTimeoutKeepsRuntimeAliveAndReusesNode() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory()
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .milliseconds(100)
        )

        let first = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        #expect(await factory.makeCount == 1)
        await first.close()

        // 租约释放后，但在 100ms 宽限期内，runtime 仍保持 running，未执行 close
        #expect(await registry.status(profileID: "p") == .running)
        #expect(await factory.closeCount == 0)

        // 在宽限期内发起新连接，应该复用既有 node，不重复创建
        let second = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.2"))
        #expect(await factory.makeCount == 1)
        await second.close()

        // 等待宽限期超时后，自动停止
        try await Task.sleep(for: .milliseconds(150))
        #expect(await registry.status(profileID: "p") == .stopped)
        #expect(await factory.closeCount == 1)
    }

    @Test("回前台健康检查期间新建 lease 不得停止 runtime")
    func resumeDoesNotStopRuntimeWithNewLease() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory(
            healthDelay: .milliseconds(200),
            healthyAfterSuspension: false
        )
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .seconds(45)
        )

        let first = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        await first.close()

        let resuming = Task { await registry.resumeAfterBackground(idleFor: 60) }
        while await factory.healthCheckCount == 0 {
            await Task.yield()
        }
        // 健康检查还在等待时，监控/终端发起了新连接。
        let second = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        await resuming.value

        #expect(await registry.status(profileID: "p") == .running)
        #expect(await factory.closeCount == 0)
        await second.close()
    }

    @Test("退后台恢复时保留健康空闲节点并在后续连接中复用")
    func resumeAfterBackgroundKeepsHealthyIdleRuntimeWarm() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory(healthyAfterSuspension: true)
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .seconds(45)
        )

        let lease = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        #expect(await factory.makeCount == 1)
        await lease.close()

        // 仍在 45s 空闲宽限期内
        #expect(await registry.status(profileID: "p") == .running)

        // 后台闲置 <= 30s 时不作处理
        await registry.resumeAfterBackground(idleFor: 10)
        #expect(await registry.status(profileID: "p") == .running)
        #expect(await factory.healthCheckCount == 0)

        // 后台闲置 > 30s 时先做健康检查；健康则保留热节点
        await registry.resumeAfterBackground(idleFor: 35)
        #expect(await registry.status(profileID: "p") == .running)
        #expect(await factory.closeCount == 0)
        #expect(await factory.healthCheckCount == 1)

        // 下一次连接直接复用，不重新创建节点
        let second = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.2"))
        #expect(await factory.makeCount == 1)
        await second.close()
    }

    @Test("退后台恢复时清理不健康的空闲节点")
    func resumeAfterBackgroundEvictsUnhealthyIdleRuntime() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory(healthyAfterSuspension: false)
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .seconds(45)
        )

        let lease = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        await lease.close()

        await registry.resumeAfterBackground(idleFor: 35)
        #expect(await registry.status(profileID: "p") == .stopped)
        #expect(await factory.closeCount == 1)
        #expect(await factory.healthCheckCount == 1)

        // 下一次连接重新创建节点
        let second = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.2"))
        #expect(await factory.makeCount == 2)
        await second.close()
    }

    @Test("退后台恢复时不影响仍有活跃租约的节点")
    func resumeAfterBackgroundPreservesActiveLeases() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory()
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .seconds(45)
        )

        let lease = try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        #expect(await factory.makeCount == 1)

        // 有活跃租约时，后台闲置 > 30s 不会被误杀，也不做健康检查
        await registry.resumeAfterBackground(idleFor: 60)
        #expect(await registry.status(profileID: "p") == .running)
        #expect(await factory.closeCount == 0)
        #expect(await factory.healthCheckCount == 0)

        await lease.close()
    }

    @Test("私有网络启动阶段会上报诊断样本")
    func privateNetworkEmitsPhaseSamples() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory()
        let recorder = PhaseRecorder()
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .zero,
            diagnosticsSink: recorder
        )

        let lease = try await registry.openProxy(
            profileID: "p",
            to: SSHEndpoint(host: "100.64.0.1"),
            diagnostics: ConnectionDiagnosticsContext(
                targetAddress: "100.64.0.1",
                targetPort: 22,
                connectionKind: "terminal",
                launchKind: "new"
            )
        )
        await lease.close()

        let samples = recorder.samples()
        let phases = samples.map(\.phase)
        #expect(phases.contains("profile_load"))
        #expect(phases.contains("credential_load"))
        #expect(phases.contains("state_prepare"))
        #expect(phases.contains("route_setup"))
        #expect(phases.contains("socks_proxy"))
        #expect(samples.allSatisfy { $0.context.route == "private_network" })
        #expect(samples.contains { $0.context.routeProvider == "tailscale" })
        #expect(samples.allSatisfy { $0.context.targetAddress == "100.64.0.1" })
    }

    @Test("SOCKS 失败样本带 error stage 和错误文本")
    func socksFailureRecordsError() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory(failingProxy: true)
        let recorder = PhaseRecorder()
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .zero,
            diagnosticsSink: recorder
        )

        await #expect(throws: PrivateNetworkError.self) {
            try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        }

        let failed = recorder.samples().last { $0.phase == "socks_proxy" }
        #expect(failed?.outcome == .failure)
        #expect(failed?.errorStage == "socks_proxy")
        #expect(failed?.errorText.isEmpty == false)
    }

    @Test("停止时取消正在启动的节点，完成后不得回插")
    func stopDuringStartDoesNotResurrectRuntime() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory(startDelay: .milliseconds(200))
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .seconds(45)
        )

        let opening = Task {
            try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        }
        while await factory.startCount == 0 {
            await Task.yield()
        }

        await registry.stop(profileID: "p")
        _ = try? await opening.value

        #expect(await registry.status(profileID: "p") == .stopped)
        #expect(await factory.makeCount == 1)
        #expect(await factory.closeCount == 1)
    }

    @Test("回前台恢复时取消后台遗留的启动任务")
    func resumeAfterBackgroundCancelsInFlightStart() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory(startDelay: .milliseconds(200))
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .seconds(45)
        )

        let opening = Task {
            try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        }
        while await factory.startCount == 0 {
            await Task.yield()
        }

        await registry.resumeAfterBackground(idleFor: 60)
        _ = try? await opening.value

        #expect(await registry.status(profileID: "p") == .stopped)
        #expect(await factory.makeCount == 1)
        #expect(await factory.closeCount == 1)
    }

    @Test("openTCPProxy失败时立即驱逐损坏节点避免后续重试复用坏连接")
    func openProxyFailureEvictsRuntime() async throws {
        let profile = PrivateNetworkProfile(
            id: "p",
            name: "Tailnet",
            provider: .tailscale,
            controlURL: "https://controlplane.tailscale.com"
        )
        let profiles = InMemoryProfiles(profile: profile)
        let credentials = InMemoryCredentialStore()
        try credentials.setPrivateNetworkAuthKey("auth", forProfile: "p")
        let factory = FakeFactory(failingProxy: true)
        let registry = PrivateNetworkRegistry(
            profileRepository: profiles,
            credentialStore: credentials,
            factory: factory,
            idleTimeout: .seconds(45)
        )

        await #expect(throws: PrivateNetworkError.self) {
            try await registry.openProxy(profileID: "p", to: SSHEndpoint(host: "100.64.0.1"))
        }

        // 握手/代理建立失败后，坏节点应该被立即停止并移出，避免下次重试继续撞坏连接
        #expect(await registry.status(profileID: "p") == .stopped)
        #expect(await factory.closeCount == 1)
    }
}

private struct InMemoryProfiles: PrivateNetworkProfileRepository {
    let value: PrivateNetworkProfile
    init(profile: PrivateNetworkProfile) { value = profile }
    func allProfiles() throws -> [PrivateNetworkProfile] { [value] }
    func profile(id: String) throws -> PrivateNetworkProfile? { id == value.id ? value : nil }
    func save(_ profile: PrivateNetworkProfile) throws {}
    func delete(id: String) throws {}
}

private actor FakeFactory: PrivateNetworkClientFactory {
    var makeCount = 0
    var closeCount = 0
    var startCount = 0
    var healthCheckCount = 0
    var isClosing = false
    var madeWhileClosing = false
    let closeDelay: Duration
    let startDelay: Duration
    let healthDelay: Duration
    let failingProxy: Bool
    let healthyAfterSuspension: Bool
    init(
        closeDelay: Duration = .zero,
        startDelay: Duration = .zero,
        healthDelay: Duration = .zero,
        failingProxy: Bool = false,
        healthyAfterSuspension: Bool = true
    ) {
        self.closeDelay = closeDelay
        self.startDelay = startDelay
        self.healthDelay = healthDelay
        self.failingProxy = failingProxy
        self.healthyAfterSuspension = healthyAfterSuspension
    }
    func makeClient(for profile: PrivateNetworkProfile, authKey: String?) async throws -> any PrivateNetworkClient {
        #expect(profile.id == "p")
        #expect(authKey == "auth")
        makeCount += 1
        madeWhileClosing = madeWhileClosing || isClosing
        try await Task.sleep(for: .milliseconds(10))
        return FakeClient(counter: self, failingProxy: failingProxy)
    }
    func didStart() async {
        startCount += 1
        try? await Task.sleep(for: startDelay)
    }
    func checkHealth() async -> Bool {
        healthCheckCount += 1
        try? await Task.sleep(for: healthDelay)
        return healthyAfterSuspension
    }
    func didClose() async {
        isClosing = true
        try? await Task.sleep(for: closeDelay)
        closeCount += 1
        isClosing = false
    }
}

private final class FakeClient: PrivateNetworkClient, @unchecked Sendable {
    private let counter: FakeFactory
    private let failingProxy: Bool
    private(set) var status: PrivateNetworkStatus = .stopped
    init(counter: FakeFactory, failingProxy: Bool = false) {
        self.counter = counter
        self.failingProxy = failingProxy
    }
    func start() async throws {
        await counter.didStart()
        status = .running
    }
    func isHealthyAfterSuspension() async -> Bool {
        await counter.checkHealth()
    }
    func openTCPProxy(to endpoint: SSHEndpoint) async throws -> any PrivateNetworkProxyLease {
        if failingProxy {
            throw PrivateNetworkError.proxyUnavailable
        }
        return FakeLease(endpoint: .init(host: "127.0.0.1", port: endpoint.port))
    }
    func close() async { status = .stopped; await counter.didClose() }
}

private final class FakeLease: PrivateNetworkProxyLease, @unchecked Sendable {
    let endpoint: PrivateNetworkProxyEndpoint
    init(endpoint: PrivateNetworkProxyEndpoint) { self.endpoint = endpoint }
    func close() async {}
}

private final class PhaseRecorder: ConnectionDiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var phaseSamples: [ConnectionPhaseSample] = []

    func record(_ sample: ConnectionPhaseSample) {
        lock.withLock { phaseSamples.append(sample) }
    }

    func record(_ summary: ConnectionTimingSummary) {}

    func samples() -> [ConnectionPhaseSample] {
        lock.withLock { phaseSamples }
    }
}
