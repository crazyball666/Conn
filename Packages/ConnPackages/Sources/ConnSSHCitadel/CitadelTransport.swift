import Citadel
import ConnSSH
import Foundation
import NIOCore

/// 基于 Citadel（SwiftNIO SSH）的 `SSHTransport` 实现。
///
/// S1 结论指导的实现要点：
/// - `algorithms: .all`——老服务器（CentOS7 类）需要 group14-sha1 KEX + CBC；
///   现代服务器忽略多余算法，无副作用。
/// - RSA 私钥连现代服务器会失败（Citadel 只发 ssh-rsa/SHA-1），此时映射为
///   `.authFailed(reason: .rsaSha2Unsupported)` 给出 ed25519 改用建议。
/// - keyboard-interactive 不支持，映射为 `.unsupportedByEngine`。
public final class CitadelTransport: SSHTransport {
    private let hostKeyStore: any HostKeyStore

    public init(hostKeyStore: any HostKeyStore) {
        self.hostKeyStore = hostKeyStore
    }

    public func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        let method = try AuthMapping.method(for: auth, username: username)

        do {
            let client = try await SSHClient.connect(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: method,
                hostKeyValidator: CitadelHostKeyVerifier.validator(
                    endpoint: endpoint,
                    hostKeyStore: hostKeyStore,
                    policy: hostKeyPolicy
                ),
                reconnect: .never,
                algorithms: .all
            )
            return CitadelSession(client: client, endpoint: endpoint)
        } catch {
            throw AuthMapping.mapConnectError(error, endpoint: endpoint, auth: auth)
        }
    }

    /// 经跳板链连接到最终目标（技术方案 §4.1）。
    ///
    /// - Parameters:
    ///   - hops: 按顺序的跳板机（不含目标）。
    ///   - target: 最终目标。
    public func connect(
        via hops: [SSHJumpHop],
        to target: SSHJumpHop,
        hostKeyPolicy: HostKeyPolicy = .tofu
    ) async throws -> any SSHSession {
        let citadelHops = hops.map {
            JumpHop(endpoint: $0.endpoint, username: $0.username, auth: $0.auth)
        }
        let citadelTarget = JumpHop(
            endpoint: target.endpoint,
            username: target.username,
            auth: target.auth
        )
        let client = try await JumpChain.connect(
            hops: citadelHops,
            target: citadelTarget,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy
        )
        // 跳板链的会话最终落在 target 上，超时诊断也该指向它而非任何一级跳板。
        return CitadelSession(client: client, endpoint: target.endpoint)
    }

    /// 兼容 ConnSSHCitadel 内部直接使用的引擎级跳板类型；业务层统一走
    /// SSHJumpHop，避免上层依赖 Citadel。
    public func connect(
        via hops: [JumpHop],
        to target: JumpHop,
        hostKeyPolicy: HostKeyPolicy = .tofu
    ) async throws -> any SSHSession {
        let genericHops = hops.map {
            SSHJumpHop(endpoint: $0.endpoint, username: $0.username, auth: $0.auth)
        }
        let genericTarget = SSHJumpHop(
            endpoint: target.endpoint,
            username: target.username,
            auth: target.auth
        )
        return try await connect(
            via: genericHops,
            to: genericTarget,
            hostKeyPolicy: hostKeyPolicy
        )
    }
}
