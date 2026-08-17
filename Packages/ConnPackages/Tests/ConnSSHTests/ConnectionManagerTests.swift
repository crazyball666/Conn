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

    @Test("调用者拥有的独立会话不进入连接池")
    func dedicatedSessionIsNotPooled() async throws {
        let counter = ConnectCounter()
        let manager = ConnectionManager(transport: CountingTransport(counter: counter))
        let target = host()

        let dedicated = try await manager.dedicatedSession(for: target)

        #expect(await manager.activeCount == 0)
        #expect(await !manager.hasPooledSession(for: target))

        let pooled = try await manager.session(for: target)
        #expect(dedicated !== pooled)
        #expect(await counter.count == 2)
    }

    @Test("不同主机返回不同实例")
    func differentHostsDifferentSessions() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let first = try await manager.session(for: host(address: "10.0.0.1"))
        let second = try await manager.session(for: host(address: "10.0.0.2"))
        #expect(first !== second)
    }

    @Test("同端点但不同主机身份不复用会话")
    func sameEndpointDifferentHostIdentityDoesNotReuseSession() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let firstHost = host("prod", address: "10.0.0.1")
        let secondHost = DomainHost(
            id: "different-id",
            name: "staging",
            address: firstHost.address,
            username: firstHost.username,
            port: firstHost.port
        )

        let first = try await manager.session(for: firstHost)
        let second = try await manager.session(for: secondHost)

        #expect(first !== second)
    }

    @Test("同端点但不同用户名或凭据不复用会话")
    func sameEndpointDifferentLoginIdentityDoesNotReuseSession() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let firstHost = DomainHost(
            id: "same-host-id",
            name: "prod-root",
            address: "10.0.0.1",
            username: "root",
            credentialRef: "credential-root"
        )
        let secondHost = DomainHost(
            id: firstHost.id,
            name: "prod-deploy",
            address: firstHost.address,
            username: "deploy",
            credentialRef: "credential-deploy"
        )

        let first = try await manager.session(for: firstHost)
        let second = try await manager.session(for: secondHost)

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

    /// App 退到后台期间系统会回收 socket，但池里的条目对此一无所知。
    ///
    /// 回归的是这个真实故障：在命令页退后台再回前台，执行命令报「连接通道已关闭」，
    /// 反复重试也不会好——因为 `session(for:)` 每次都把同一条死会话交出去，而全仓
    /// 18 个调用方里只有 `MonitorScheduler` 会在失败后 `invalidate`。用户必须切到
    /// 服务器页让采集失败一次、把死条目踢掉，命令才能执行。
    @Test("池化会话已死时不复用，改为重新握手")
    func deadPooledSessionIsNotReused() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let host = host()

        let first = try await manager.session(for: host)
        #expect(first.isConnected)

        // 模拟后台期间底层通道被回收：会话对象还在池里，但已经不能用了。
        (first as? MockSSHSession)?.simulateDisconnect()

        let second = try await manager.session(for: host)
        #expect(first !== second, "死会话不该再被交出去")
        #expect(second.isConnected)
        // 换新之后池里应当只有那条新的，不能两条都留着
        #expect(await manager.activeCount == 1)
    }

    /// 驱逐死会话时必须关掉它，否则留下一条谁都不再持有的 socket。
    @Test("被替换掉的死会话会被关闭")
    func deadPooledSessionIsClosed() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let host = host()

        let first = try await manager.session(for: host)
        let dead = try #require(first as? MockSSHSession)
        dead.simulateDisconnect()
        _ = try await manager.session(for: host)

        #expect(await dead.waitUntilClosed(), "死会话未被关闭，socket 泄漏")
    }

    /// 反向用例：活着的会话仍然必须复用，别把存活门控写成「每次都重连」。
    @Test("会话活着时仍然复用同一条")
    func livePooledSessionIsStillReused() async throws {
        let counter = ConnectCounter()
        let manager = ConnectionManager(transport: CountingTransport(counter: counter))
        let host = host()

        let first = try await manager.session(for: host)
        let second = try await manager.session(for: host)

        #expect(first === second)
        #expect(await counter.count == 1, "会话还活着却重新握手了")
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

    @Test("连接池健康查询只观察存活状态，不创建或驱逐会话")
    func reportsPooledSessionHealthWithoutMutation() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let host = host()

        #expect(await manager.pooledSessionHealth(for: host) == .absent)

        let session = try await manager.session(for: host)
        #expect(await manager.pooledSessionHealth(for: host) == .connected)

        let mock = try #require(session as? MockSSHSession)
        mock.simulateDisconnect()

        #expect(await manager.pooledSessionHealth(for: host) == .disconnected)
        #expect(await manager.activeCount == 1)
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

    @Test("同一连接的平台画像只探测一次")
    func cachesPlatformProfile() async throws {
        let detector = CountingPlatformDetector(profile: .init(kind: .macOS))
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: detector
        )
        let host = host()

        let first = try await manager.platformContext(for: host).profile
        let second = try await manager.platformContext(for: host).profile

        #expect(first == second)
        #expect(await detector.count == 1)
    }

    @Test("平台上下文原子携带连接池使用的连接身份")
    func platformContextCarriesClaimedConnectionIdentity() async throws {
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: CountingPlatformDetector(profile: .init(kind: .macOS))
        )
        let original = DomainHost(
            id: "same-host",
            name: "Original",
            address: "10.0.0.1",
            username: "root",
            credentialRef: "credential-root"
        )
        let edited = DomainHost(
            id: original.id,
            name: "Edited",
            address: original.address,
            username: "deploy",
            credentialRef: "credential-deploy"
        )

        let originalContext = try await manager.platformContext(for: original)
        let editedContext = try await manager.platformContext(for: edited)

        #expect(originalContext.connectionIdentity == SSHConnectionIdentity(host: original))
        #expect(editedContext.connectionIdentity == SSHConnectionIdentity(host: edited))
        #expect(originalContext.connectionIdentity != editedContext.connectionIdentity)
        #expect(originalContext.session !== editedContext.session)
    }

    @Test("驱逐连接会同步清除平台画像缓存")
    func invalidationClearsPlatformProfile() async throws {
        let detector = CountingPlatformDetector(profile: .init(kind: .linux))
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: detector
        )
        let host = host()

        _ = try await manager.platformContext(for: host)
        await manager.invalidate(host: host)
        _ = try await manager.platformContext(for: host)

        #expect(await detector.count == 2)
    }

    @Test("缓存画像前先验证池化连接，死连接会重新握手与探测")
    func cachedProfileDoesNotBypassDeadSessionCheck() async throws {
        let detector = CountingPlatformDetector(profile: .init(kind: .macOS))
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: detector
        )
        let host = host()

        let session = try await manager.session(for: host)
        _ = try await manager.platformContext(for: host)
        (session as? MockSSHSession)?.simulateDisconnect()
        _ = try await manager.platformContext(for: host)

        #expect(await detector.count == 2)
        #expect(await manager.activeCount == 1)
    }

    @Test("平台探测期间重连不会返回混合 session/profile context")
    func platformContextRejectsSessionReplacedDuringDetection() async throws {
        let detector = BlockingIdentityPlatformDetector()
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: detector
        )
        let host = host()
        let firstSession = try await manager.session(for: host)
        let pending = Task { try await manager.platformContext(for: host) }

        await detector.waitUntilFirstDetectionStarts()
        await manager.invalidate(host: host)
        let replacementSession = try await manager.session(for: host)
        await detector.releaseFirstDetection()

        do {
            _ = try await pending.value
            Issue.record("Expected invalidated platform context to fail")
        } catch {
            #expect(error as? SSHError == .channelClosed)
        }

        let replacementContext = try await manager.platformContext(for: host)
        let detectedSessionIDs = await detector.detectedSessionIDs

        #expect(firstSession !== replacementSession)
        #expect(replacementContext.session === replacementSession)
        #expect(replacementContext.profile.release == "profile-2")
        #expect(detectedSessionIDs == [
            ObjectIdentifier(firstSession),
            ObjectIdentifier(replacementSession),
        ])
    }

    @Test("握手期间 invalidateAll → 握手成功也不回插，会话被关掉，调用方拿到错误")
    func handshakeFinishedAfterInvalidateAllIsNotReinserted() async throws {
        // 关键：这个 transport 的握手**不响应取消**，模拟 Citadel 的
        // SSHClient.connect（全程 EventLoopFuture.get()）。所以 invalidateAll 的
        // cancel() 拦不住它成功返回——回插与否只能靠 session(for:) 的身份确认。
        let closed = CloseFlag()
        let manager = ConnectionManager(
            transport: UncancellableTransport(delay: .milliseconds(300), closed: closed)
        )
        let host = host()

        // 用 Task 而非 async let：下面要在 #expect 闭包里 await 它
        let pending = Task { try await manager.session(for: host) }
        // 等握手真正开始（条目已是 .connecting）再驱逐
        try await waitUntil { await manager.hasPooledSession(for: host) }
        await manager.invalidateAll()

        await #expect(throws: SSHError.self) {
            _ = try await pending.value
        }
        // 池必须是空的：若无条件回插，这里会留下一条本该被丢弃的连接
        #expect(await !manager.hasPooledSession(for: host))
        #expect(await manager.activeCount == 0)
        // 被丢弃的会话必须关掉，否则是一条谁也不再持有的泄漏 socket
        #expect(await closed.waitUntilClosed())
    }

    @Test("握手期间 invalidate(host:) → 之后新的 session 重新握手，不复用旧连接")
    func handshakeFinishedAfterInvalidateHostStartsFreshConnection() async throws {
        let closed = CloseFlag()
        let manager = ConnectionManager(
            transport: UncancellableTransport(delay: .milliseconds(300), closed: closed)
        )
        let host = host()

        let pending = Task { try await manager.session(for: host) }
        try await waitUntil { await manager.hasPooledSession(for: host) }
        await manager.invalidate(host: host)
        await #expect(throws: SSHError.self) {
            _ = try await pending.value
        }

        // 被驱逐后新的请求应当拿到一条全新的、真正在池里的会话
        let fresh = try await manager.session(for: host)
        #expect(await manager.activeCount == 1)
        #expect(await manager.hasPooledSession(for: host))
        _ = fresh
    }
}

/// 轮询等待某条件成立（最多 2 秒），避免用固定 sleep 赌时序。
private func waitUntil(
    _ condition: @Sendable () async -> Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - 测试替身

private actor ConnectCounter {
    private(set) var count = 0
    func increment() {
        count += 1
    }
}

private actor CountingPlatformDetector: RemotePlatformDetecting {
    private(set) var count = 0
    private let profile: RemotePlatformProfile

    init(profile: RemotePlatformProfile) {
        self.profile = profile
    }

    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        _ = session
        count += 1
        return profile
    }
}

private actor BlockingIdentityPlatformDetector: RemotePlatformDetecting {
    private(set) var detectedSessionIDs: [ObjectIdentifier] = []
    private var firstDetectionStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstDetectionRelease: CheckedContinuation<Void, Never>?

    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        detectedSessionIDs.append(ObjectIdentifier(session))
        let detectionNumber = detectedSessionIDs.count

        if detectionNumber == 1 {
            firstDetectionStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                firstDetectionRelease = continuation
            }
        }

        return RemotePlatformProfile(
            kind: .linux,
            release: "profile-\(detectionNumber)"
        )
    }

    func waitUntilFirstDetectionStarts() async {
        guard !firstDetectionStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstDetection() {
        firstDetectionRelease?.resume()
        firstDetectionRelease = nil
    }
}

private actor ResolvedFlag {
    private(set) var wasResolved = false
    func mark() {
        wasResolved = true
    }
}

/// 记录会话是否被关闭。
private actor CloseFlag {
    private(set) var isClosed = false

    func markClosed() {
        isClosed = true
    }

    /// 等到会话被关闭（关闭是 fire-and-forget 的 Task，不能同步读）。最多等 2 秒。
    func waitUntilClosed() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if isClosed { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return isClosed
    }
}

/// 握手慢且**不响应取消**的 transport，用于复现「invalidate 之后握手才成功」。
///
/// 这正是 Citadel 的行为：`SSHClient.connect` 全程建在 `EventLoopFuture.get()` 上，
/// `Task.cancel()` 拦不住它。所以这里刻意不能用 `Task.sleep`（它会因取消提前抛错，
/// 反而测不到「握手成功后回插」那条路径），改用挂在全局队列上的定时器。
private final class UncancellableTransport: SSHTransport {
    private let delay: Duration
    private let closed: CloseFlag

    init(delay: Duration, closed: CloseFlag) {
        self.delay = delay
        self.closed = closed
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
        return CloseRecordingSession(closed: closed)
    }
}

/// 只关心 `close()` 有没有被调用的假会话；其余能力用不到，一律抛 channelClosed。
private final class CloseRecordingSession: SSHSession {
    private let closed: CloseFlag
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let state: AsyncStream<SSHSessionState>
    let isConnected = true

    init(closed: CloseFlag) {
        self.closed = closed
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        throw SSHError.channelClosed
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw SSHError.channelClosed
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        throw SSHError.channelClosed
    }

    func sftp() async throws -> any RemoteFileSystem {
        throw SSHError.channelClosed
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        throw SSHError.channelClosed
    }

    func close() async {
        await closed.markClosed()
        continuation.yield(.closed)
        continuation.finish()
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
