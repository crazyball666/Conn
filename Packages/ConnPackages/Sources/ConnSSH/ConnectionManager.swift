import ConnKit
import Foundation

/// 为某主机解析认证材料（从 Keychain 取出）。
///
/// 用闭包而非协议，让 App 层可直接注入 Keychain 读取逻辑，测试可注入常量。
/// 凭据只在此刻现取现用，不长驻内存（技术方案 §4.7）。
public typealias AuthResolver = @Sendable (ConnKit.Host) async throws -> SSHAuth
public typealias JumpChainResolver = @Sendable (ConnKit.Host) async throws -> [SSHJumpHop]

/// 全局唯一的连接池管理器（技术方案 §4.1）。
///
/// 每主机复用 1 条 SSH 连接；并发请求同一主机只握手一次。经 Environment 注入，
/// 禁止单例直取——演示模式与测试可整体替换 `SSHTransport`。
///
/// 指纹校验（TOFU）发生在握手内部，是 `transport` 的职责；本管理器只管池化。
public actor ConnectionManager {
    private let transport: any SSHTransport
    private let resolveAuth: AuthResolver
    private let resolveJumpChain: JumpChainResolver

    /// 连接池必须区分配置不同的主机，即使它们暂时指向同一端点。
    ///
    /// `address:port` 只能标识网络端点，不能标识登录身份。若两个 Host 共享端点
    /// 但用户名、密钥或跳板链不同，复用同一 SSH 会话会把错误的认证上下文交给调用方。
    private struct PoolKey: Hashable {
        let id: String
        let address: String
        let port: Int
        let username: String
        let authKind: String
        let credentialRef: String?
        let keyUUID: String?
        let jumpChain: [String]

        init(host: ConnKit.Host) {
            id = host.id
            address = host.address
            port = host.port
            username = host.username
            authKind = host.authKind.rawValue
            credentialRef = host.credentialRef
            keyUUID = host.keyUUID
            jumpChain = host.jumpChain
        }
    }

    /// 每主机的会话，或正在建立中的任务（用于并发去重）。
    private enum Entry {
        case connecting(Task<any SSHSession, Error>)
        case connected(any SSHSession)
    }

    private var entries: [PoolKey: Entry] = [:]

    /// - Parameters:
    ///   - transport: SSH 引擎（已注入其所需的 `HostKeyStore`）。
    ///   - resolveAuth: 主机 → 认证材料。默认返回空密码，仅供 Mock 场景；
    ///     App 层必须注入真实的 Keychain 读取。
    public init(
        transport: any SSHTransport,
        resolveAuth: @escaping AuthResolver = { _ in .password("") },
        resolveJumpChain: @escaping JumpChainResolver = { host in
            guard host.jumpChain.isEmpty else { throw SSHError.jumpChainUnsupported }
            return []
        }
    ) {
        self.transport = transport
        self.resolveAuth = resolveAuth
        self.resolveJumpChain = resolveJumpChain
    }

    /// 保留旧的两参数构造入口，避免现有调用方因新增跳板解析器而失去
    /// 二进制/源码兼容性；默认拒绝未解析的跳板配置。
    public init(
        transport: any SSHTransport,
        resolveAuth: @escaping AuthResolver
    ) {
        self.init(
            transport: transport,
            resolveAuth: resolveAuth,
            resolveJumpChain: { host in
                guard host.jumpChain.isEmpty else { throw SSHError.jumpChainUnsupported }
                return []
            }
        )
    }

    /// 取（或建立）到某主机的会话。同一主机复用同一条连接。
    ///
    /// 并发调用同一主机时，只有第一个发起握手，其余等待同一 Task 结果。
    public func session(for host: ConnKit.Host) async throws -> any SSHSession {
        let key = poolKey(for: host)

        if let entry = entries[key] {
            switch entry {
            case let .connected(session):
                if session.isConnected {
                    return session
                }
                // 池化会话的底层通道已死——最常见于 App 退到后台、系统回收了 socket。
                //
                // 必须在这里就地驱逐，不能把它交出去：全仓 18 个 `session(for:)` 调用方
                // 中只有 `MonitorScheduler` 会在操作失败后 `invalidate(host:)`，其余
                // （命令、Docker、文件、日志、终端）拿到死会话就只是报错，没有人清池子。
                // 于是「在命令页回前台执行命令」会反复失败，直到用户切去服务器页让采集
                // 失败一次，把条目踢掉为止。
                //
                // 回前台本来还有一道 `resumeAfterBackground` → `invalidateAll()`，但它
                // 被 `dashboardConfig != nil` 收窄到「仪表盘此刻确实在跑」——那道收窄是
                // 为了不掐断骑在同一条连接上的终端，是对的，只是覆盖不到别的页面。
                entries[key] = nil
                // fire-and-forget：对着一条半死的 socket `await close()` 可能把调用方一起卡住。
                Task { await session.close() }
            case let .connecting(task):
                return try await claim(task, key: key)
            }
        }

        let resolve = resolveAuth
        let resolveJumps = resolveJumpChain
        let engine = transport
        let task = Task<any SSHSession, Error> {
            let auth = try await resolve(host)
            let target = SSHJumpHop(
                endpoint: SSHEndpoint(host: host.address, port: host.port),
                username: host.username,
                auth: auth
            )
            let hops = try await resolveJumps(host)
            return try await engine.connect(via: hops, to: target, hostKeyPolicy: .tofu)
        }
        entries[key] = .connecting(task)
        return try await claim(task, key: key)
    }

    /// 等一条正在进行的握手，并在成功后**确认它仍被池认领**再回插。
    ///
    /// 为什么必须确认：`invalidate(host:)` / `invalidateAll()` 对 `.connecting` 只能
    /// `cancel()`，而 Citadel 的 `SSHClient.connect` 全程建在 `EventLoopFuture.get()` 上，
    /// **不响应 Swift 并发的取消**——cancel() 拦不住它成功返回。若成功后无条件写
    /// `entries[key] = .connected(session)`，一次「回前台 → invalidateAll」就会被随后
    /// 完成的旧握手悄悄撤销：池里留下一条本该丢弃的连接（回前台场景下大概率已死），
    /// 之后每轮采集都拿到它、失败、再 invalidate，用户看到的是反复转圈。
    /// 所以判据不是「握手有没有被取消」，而是「回插时条目是不是还是我发起的那条」。
    ///
    /// 判定用 `Task` 的身份相等（`Task` 是 `Hashable`，按实例比较），不用「条目非空」
    /// ——invalidate 后紧接着又发起一次新握手时，条目非空但已经不是自己那条了。
    private func claim(_ task: Task<any SSHSession, Error>, key: PoolKey) async throws -> any SSHSession {
        let session: any SSHSession
        do {
            session = try await task.value
        } catch {
            // 握手失败，清除条目，允许下次重试。只清自己那条：期间若已被 invalidate
            // 并重新发起握手，条目属于新任务，误删会让新任务的结果无处回插。
            if case let .connecting(current)? = entries[key], current == task {
                entries[key] = nil
            }
            throw error
        }

        guard let entry = entries[key] else {
            // 条目已被 invalidate/disconnect 清掉：这条连接已无人认领。不能回插，
            // 否则等于撤销那次 invalidate；也不能就这么返回给调用方——池里没有它，
            // 谁都不会再关它，最后变成一条泄漏的 socket。关掉并让调用方走重试路径。
            Task { await session.close() }
            throw SSHError.channelClosed
        }
        switch entry {
        case let .connecting(current) where current == task:
            entries[key] = .connected(session)
            return session
        case let .connected(pooled):
            // 通常是同一条握手的另一个等待者已先回插，池里那条就是自己这条。
            // 但也可能是「中途被 invalidate，另一条握手抢先占了位」——那时自己这条
            // 已无人认领，必须关掉，否则留下一条谁都不持有的 socket。
            if pooled !== session {
                Task { await session.close() }
            }
            return pooled
        case .connecting:
            // 条目已换成另一条握手：说明中途被 invalidate 过且已重新发起。同上，丢弃。
            Task { await session.close() }
            throw SSHError.channelClosed
        }
    }

    /// 驱逐某主机的池化会话（不等待关闭）。
    ///
    /// 操作因传输层错误（通道 EOF、连接死）抛错时调用：把死会话踢出池，
    /// **下次 `session(for:)` 会重新握手**——这样断网/服务器空闲超时后，
    /// 仪表盘下一轮采集（3s/30s）即自动重连,而不是卡死到 App 重启。
    /// 关闭在后台 fire-and-forget,避免对死 socket 调 `close()` 卡住调用方。
    public func invalidate(host: ConnKit.Host) {
        let key = poolKey(for: host)
        guard let entry = entries.removeValue(forKey: key) else { return }
        switch entry {
        case let .connected(session):
            Task { await session.close() }
        case let .connecting(task):
            task.cancel()
        }
    }

    /// 池中是否已有该主机的条目（已连接或正在握手）。
    ///
    /// 采集调度用它区分两件事：**复用现成会话跑一条命令**，还是**要先握手**。
    /// 后者在主机本来有读数时意味着「重连中」，UI 据此显示转圈而非静默。
    public func hasPooledSession(for host: ConnKit.Host) -> Bool {
        entries[poolKey(for: host)] != nil
    }

    /// 驱逐全部池化会话（不等待关闭）。
    ///
    /// 主要用于**回前台**：后台期间 socket 多半已被服务器 idle timeout 或系统回收，
    /// 对死 socket 同步 `await close()` 会卡住调用方，所以关闭一律 fire-and-forget。
    /// 语义同 `invalidate(host:)`，只是作用于全部条目——包括正在握手的那些。
    ///
    /// 对 `.connecting` 调 `cancel()` 是**必要但不充分**的：Citadel 的握手不响应取消
    /// （见 `claim(_:key:)`），cancel 之后它照样可能成功返回。真正拦住「握手成功后
    /// 把自己塞回池里」的是 `claim(_:key:)` 的回插前身份确认——本方法先
    /// `entries.removeAll()`，随后完成的握手因认领不到条目而被丢弃并关闭。
    public func invalidateAll() {
        let current = entries
        entries.removeAll()
        for entry in current.values {
            switch entry {
            case let .connected(session):
                Task { await session.close() }
            case let .connecting(task):
                task.cancel()
            }
        }
    }

    /// 断开并移除某主机的会话。
    public func disconnect(host: ConnKit.Host) async {
        let key = poolKey(for: host)
        guard let entry = entries.removeValue(forKey: key) else { return }
        switch entry {
        case let .connected(session):
            await session.close()
        case let .connecting(task):
            task.cancel()
        }
    }

    /// 当前池中已连接的主机数（测试与诊断用）。
    public var activeCount: Int {
        entries.values.filter {
            if case .connected = $0 {
                true
            } else {
                false
            }
        }.count
    }

    private func poolKey(for host: ConnKit.Host) -> PoolKey {
        PoolKey(host: host)
    }
}
