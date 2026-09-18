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
    var isClosing = false
    var madeWhileClosing = false
    let closeDelay: Duration
    init(closeDelay: Duration = .zero) { self.closeDelay = closeDelay }
    func makeClient(for profile: PrivateNetworkProfile, authKey: String?) async throws -> any PrivateNetworkClient {
        #expect(profile.id == "p")
        #expect(authKey == "auth")
        makeCount += 1
        madeWhileClosing = madeWhileClosing || isClosing
        try await Task.sleep(for: .milliseconds(10))
        return FakeClient(counter: self)
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
    private(set) var status: PrivateNetworkStatus = .stopped
    init(counter: FakeFactory) { self.counter = counter }
    func start() async throws { status = .running }
    func openTCPProxy(to endpoint: SSHEndpoint) async throws -> any PrivateNetworkProxyLease {
        FakeLease(endpoint: .init(host: "127.0.0.1", port: endpoint.port))
    }
    func close() async { status = .stopped; await counter.didClose() }
}

private final class FakeLease: PrivateNetworkProxyLease, @unchecked Sendable {
    let endpoint: PrivateNetworkProxyEndpoint
    init(endpoint: PrivateNetworkProxyEndpoint) { self.endpoint = endpoint }
    func close() async {}
}
