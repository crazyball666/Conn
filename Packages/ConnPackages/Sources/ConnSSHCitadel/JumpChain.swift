import Citadel
import ConnSSH
import Foundation

/// 跳板链的一跳。
public struct JumpHop: Sendable {
    public let endpoint: SSHEndpoint
    public let username: String
    public let auth: SSHAuth

    public init(endpoint: SSHEndpoint, username: String, auth: SSHAuth) {
        self.endpoint = endpoint
        self.username = username
        self.auth = auth
    }
}

/// 沿跳板链建立到最终目标的 Citadel 连接。
///
/// S1 已验证 `host → bastion → internal` 经 direct-tcpip 可行。用 Citadel 的
/// `client.jump(to:)` 一等公民 API 递归建链：先连第一跳，在其之上开
/// direct-tcpip 通道跑下一层 SSH 握手，逐级嵌套。
enum JumpChain {
    /// - Parameters:
    ///   - hops: 按连接顺序的跳板机（不含最终目标）。空数组表示直连。
    ///   - target: 最终目标端点、用户名、认证。
    /// - Returns: 到最终目标的 `SSHClient`。
    /// - Throws: `SSHError.jumpChainFailed(hopIndex:hopHost:)` 指明卡在第几级。
    static func connect(
        hops: [JumpHop],
        target: JumpHop,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> SSHClient {
        // 第一跳（或无跳板时直连目标）
        guard let firstHop = hops.first else {
            return try await directConnect(target, hostKeyStore: hostKeyStore, hostKeyPolicy: hostKeyPolicy)
        }

        var client = try await connectHop(
            firstHop,
            hopIndex: 0,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy
        )

        // 逐级跳到后续跳板
        for (offset, hop) in hops.dropFirst().enumerated() {
            let hopIndex = offset + 1
            do {
                client = try await client.jump(
                    to: settings(for: hop, hostKeyStore: hostKeyStore, hostKeyPolicy: hostKeyPolicy)
                )
            } catch let error as CitadelHostKeyValidationError {
                throw error.sshError
            } catch {
                throw SSHError.jumpChainFailed(hopIndex: hopIndex, hopHost: hop.endpoint.host)
            }
        }

        // 最后一跳跳到真正的目标
        do {
            return try await client.jump(
                to: settings(for: target, hostKeyStore: hostKeyStore, hostKeyPolicy: hostKeyPolicy)
            )
        } catch let error as CitadelHostKeyValidationError {
            throw error.sshError
        } catch let error as SSHError {
            throw error
        } catch {
            throw SSHError.jumpChainFailed(hopIndex: hops.count, hopHost: target.endpoint.host)
        }
    }

    private static func connectHop(
        _ hop: JumpHop,
        hopIndex: Int,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> SSHClient {
        do {
            return try await directConnect(
                hop,
                hostKeyStore: hostKeyStore,
                hostKeyPolicy: hostKeyPolicy
            )
        } catch let error as SSHError {
            // A host-key failure is a security decision, not merely a connectivity
            // failure. Preserve it so callers can show the recorded/presented
            // fingerprints and never reduce it to a generic jump-chain error.
            switch error {
            case .hostKeyMismatch, .hostKeyStoreUnavailable:
                throw error
            default:
                break
            }
            // directConnect 已给出诊断，但需补上「卡在第几级」的定位
            throw SSHError.jumpChainFailed(hopIndex: hopIndex, hopHost: hop.endpoint.host)
        }
    }

    private static func directConnect(
        _ hop: JumpHop,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> SSHClient {
        let method = try AuthMapping.method(for: hop.auth, username: hop.username)
        do {
            return try await SSHClient.connect(
                host: hop.endpoint.host,
                port: hop.endpoint.port,
                authenticationMethod: method,
                hostKeyValidator: CitadelHostKeyVerifier.validator(
                    endpoint: hop.endpoint,
                    hostKeyStore: hostKeyStore,
                    policy: hostKeyPolicy
                ),
                reconnect: .never,
                algorithms: .all
            )
        } catch {
            throw AuthMapping.mapConnectError(error, endpoint: hop.endpoint, auth: hop.auth)
        }
    }

    private static func settings(
        for hop: JumpHop,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: HostKeyPolicy
    ) throws -> SSHClientSettings {
        let method = try AuthMapping.method(for: hop.auth, username: hop.username)
        return SSHClientSettings(
            host: hop.endpoint.host,
            port: hop.endpoint.port,
            authenticationMethod: { method },
            hostKeyValidator: CitadelHostKeyVerifier.validator(
                endpoint: hop.endpoint,
                hostKeyStore: hostKeyStore,
                policy: hostKeyPolicy
            )
        )
    }
}
