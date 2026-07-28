import ConnKit
import Foundation
import Testing
@testable import ConnSSH

private typealias DomainHost = ConnKit.Host

@Suite("ConnectionManager — 连接池")
struct ConnectionManagerTests {
    private func host(_ name: String = "web-01", address: String = "10.0.0.1", port: Int = 22) -> DomainHost {
        DomainHost(name: name, address: address, username: "root", port: port)
    }

    @Test("同一主机两次 session 返回同一实例（池化复用）")
    func poolsSameHost() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let host = host()
        let first = try await manager.session(for: host)
        let second = try await manager.session(for: host)
        #expect(first === second)
    }

    @Test("不同主机返回不同实例")
    func differentHostsDifferentSessions() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let first = try await manager.session(for: host(address: "10.0.0.1"))
        let second = try await manager.session(for: host(address: "10.0.0.2"))
        #expect(first !== second)
    }

    @Test("并发请求同一主机只握手一次（去重）")
    func concurrentRequestsDeduplicate() async throws {
        let counter = ConnectCounter()
        let manager = ConnectionManager(transport: CountingTransport(counter: counter))
        let host = host()

        async let req1 = manager.session(for: host)
        async let req2 = manager.session(for: host)
        async let req3 = manager.session(for: host)
        let (sa, sb, sc) = try await (req1, req2, req3)

        #expect(sa === sb)
        #expect(sb === sc)
        #expect(await counter.count == 1)
    }

    @Test("断开后再次 session 重新建立")
    func reconnectsAfterDisconnect() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let host = host()
        let first = try await manager.session(for: host)
        await manager.disconnect(host: host)
        let second = try await manager.session(for: host)
        #expect(first !== second)
    }

    @Test("握手失败不污染池，下次可重试")
    func failedHandshakeAllowsRetry() async throws {
        let transport = MockSSHTransport(behavior: .init(failConnect: .connectionRefused(
            endpoint: SSHEndpoint(host: "10.0.0.1", port: 22)
        )))
        let manager = ConnectionManager(transport: transport)
        await #expect(throws: SSHError.self) {
            _ = try await manager.session(for: host())
        }
        // 池中不应残留失败条目
        #expect(await manager.activeCount == 0)
    }

    @Test("resolveAuth 被调用以取凭据")
    func invokesAuthResolver() async throws {
        let flag = ResolvedFlag()
        let manager = ConnectionManager(transport: MockSSHTransport()) { _ in
            await flag.mark()
            return .password("secret")
        }
        _ = try await manager.session(for: host())
        #expect(await flag.wasResolved)
    }

    @Test("握手后池中有会话，invalidate 后没有")
    func tracksPooledSession() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let host = host()

        #expect(await !manager.hasPooledSession(for: host))
        _ = try await manager.session(for: host)
        #expect(await manager.hasPooledSession(for: host))

        await manager.invalidate(host: host)
        #expect(await !manager.hasPooledSession(for: host))
    }

    @Test("invalidateAll 清空全部池化会话")
    func invalidateAllClearsPool() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let first = host(address: "10.0.0.1")
        let second = host(address: "10.0.0.2")
        _ = try await manager.session(for: first)
        _ = try await manager.session(for: second)
        #expect(await manager.activeCount == 2)

        await manager.invalidateAll()

        #expect(await manager.activeCount == 0)
        #expect(await !manager.hasPooledSession(for: first))
        #expect(await !manager.hasPooledSession(for: second))
    }
}

// MARK: - 测试替身

private actor ConnectCounter {
    private(set) var count = 0
    func increment() {
        count += 1
    }
}

private actor ResolvedFlag {
    private(set) var wasResolved = false
    func mark() {
        wasResolved = true
    }
}

/// 记录 connect 被调用次数的 transport，用于并发去重测试。
private final class CountingTransport: SSHTransport {
    let counter: ConnectCounter
    init(counter: ConnectCounter) {
        self.counter = counter
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        await counter.increment()
        // 加一点延迟，确保并发请求在第一个完成前都进来
        try? await Task.sleep(for: .milliseconds(20))
        return MockSSHSession(endpoint: endpoint, behavior: .init())
    }
}
