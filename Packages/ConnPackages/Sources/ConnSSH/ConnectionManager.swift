import ConnKit
import Foundation

/// 为某主机解析认证材料（从 Keychain / Secure Enclave 取出）。
///
/// 用闭包而非协议，让 App 层可直接注入 Keychain 读取逻辑，测试可注入常量。
/// 凭据只在此刻现取现用，不长驻内存（技术方案 §4.7）。
public typealias AuthResolver = @Sendable (ConnKit.Host) async throws -> SSHAuth

/// 全局唯一的连接池管理器（技术方案 §4.1）。
///
/// 每主机复用 1 条 SSH 连接；并发请求同一主机只握手一次。经 Environment 注入，
/// 禁止单例直取——演示模式与测试可整体替换 `SSHTransport`。
///
/// 指纹校验（TOFU）发生在握手内部，是 `transport` 的职责；本管理器只管池化。
public actor ConnectionManager {
    private let transport: any SSHTransport
    private let resolveAuth: AuthResolver

    /// 每主机的会话，或正在建立中的任务（用于并发去重）。
    private enum Entry {
        case connecting(Task<any SSHSession, Error>)
        case connected(any SSHSession)
    }

    private var entries: [String: Entry] = [:]

    /// - Parameters:
    ///   - transport: SSH 引擎（已注入其所需的 `HostKeyStore`）。
    ///   - resolveAuth: 主机 → 认证材料。默认返回空密码，仅供 Mock 场景；
    ///     App 层必须注入真实的 Keychain 读取。
    public init(
        transport: any SSHTransport,
        resolveAuth: @escaping AuthResolver = { _ in .password("") }
    ) {
        self.transport = transport
        self.resolveAuth = resolveAuth
    }

    /// 取（或建立）到某主机的会话。同一主机复用同一条连接。
    ///
    /// 并发调用同一主机时，只有第一个发起握手，其余等待同一 Task 结果。
    public func session(for host: ConnKit.Host) async throws -> any SSHSession {
        let key = poolKey(for: host)

        if let entry = entries[key] {
            switch entry {
            case let .connected(session):
                return session
            case let .connecting(task):
                return try await task.value
            }
        }

        let resolve = resolveAuth
        let engine = transport
        let task = Task<any SSHSession, Error> {
            let auth = try await resolve(host)
            return try await engine.connect(
                SSHEndpoint(host: host.address, port: host.port),
                username: host.username,
                auth: auth,
                hostKeyPolicy: .tofu
            )
        }
        entries[key] = .connecting(task)

        do {
            let session = try await task.value
            entries[key] = .connected(session)
            return session
        } catch {
            // 握手失败，清除条目，允许下次重试
            entries[key] = nil
            throw error
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
    /// 与 `disconnectAll()` 的区别：那个会 `await session.close()` 逐条等待，
    /// 而本方法用于**回前台**——后台期间 socket 多半已被服务器 idle timeout
    /// 或系统回收，对死 socket 同步 close 会卡住调用方。语义同 `invalidate(host:)`，
    /// 只是作用于全部条目。
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

    /// 断开全部（App 进入后台或退出时）。
    public func disconnectAll() async {
        let current = entries
        entries.removeAll()
        for entry in current.values {
            if case let .connected(session) = entry {
                await session.close()
            }
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

    private func poolKey(for host: ConnKit.Host) -> String {
        "\(host.address):\(host.port)"
    }
}
