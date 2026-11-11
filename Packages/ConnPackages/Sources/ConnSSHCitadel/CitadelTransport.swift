import Citadel
import ConnKit
import ConnSSH
import ConnPrivateNetwork
import Foundation
import NIOCore

/// SSH 传输层统一的连接策略。
///
/// 显式覆盖 Citadel 的 30 秒默认值，避免不可达的内网主机长时间停留在连接中。
/// 对私有网络或代理场景使用宽限超时，为 WireGuard 握手、NAT 穿透及中继保留裕量。
enum CitadelConnectionPolicy {
    static let tcpConnectTimeout: TimeAmount = .seconds(10)
    static let proxyConnectTimeout: TimeAmount = .seconds(25)
}

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
    private let privateNetworkRegistry: PrivateNetworkRegistry?
    private let diagnosticsSink: (any ConnectionDiagnosticsSink)?

    public init(
        hostKeyStore: any HostKeyStore,
        privateNetworkRegistry: PrivateNetworkRegistry? = nil,
        diagnosticsSink: (any ConnectionDiagnosticsSink)? = nil
    ) {
        self.hostKeyStore = hostKeyStore
        self.privateNetworkRegistry = privateNetworkRegistry
        self.diagnosticsSink = diagnosticsSink
    }

    public func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        let client = try await connectDirect(
            connectionEndpoint: endpoint,
            hostKeyEndpoint: endpoint,
            username: username,
            auth: auth,
            hostKeyPolicy: hostKeyPolicy
        )
        return CitadelSession(client: client, endpoint: endpoint)
    }

    /// 经跳板链连接到最终目标（技术方案 §4.1）。
    ///
    /// - Parameters:
    ///   - hops: 按顺序的跳板机（不含目标）。
    ///   - target: 最终目标。
    public func connect(
        via hops: [SSHJumpHop],
        to target: SSHJumpHop,
        hostKeyPolicy: HostKeyPolicy = .tofu,
        diagnostics: ConnectionDiagnosticsContext = .init(connectionRef: "")
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
        return CitadelSession(client: client, endpoint: target.endpoint, diagnostics: diagnostics)
    }

    public func connect(
        _ plan: SSHConnectionPlan,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        if plan.privateNetworkProfileID != nil, plan.proxyConfiguration != nil {
            throw SSHError.privateNetworkAndProxyConflict
        }

        guard let profileID = plan.privateNetworkProfileID else {
            if let proxy = plan.proxyConfiguration {
                return try await connectThroughExternalProxy(
                    proxy,
                    password: plan.proxyPassword,
                    plan: plan,
                    hostKeyPolicy: hostKeyPolicy
                )
            }
            let started = Date()
            do {
                let session = try await connect(
                    via: plan.hops,
                    to: plan.target,
                    hostKeyPolicy: hostKeyPolicy,
                    diagnostics: plan.diagnostics
                )
                recordPhase("ssh_handshake", started: started, context: plan.diagnostics)
                return session
            } catch {
                recordPhase("ssh_handshake", started: started, context: plan.diagnostics, error: error)
                throw error
            }
        }
        guard let privateNetworkRegistry else {
            throw SSHError.privateNetworkUnsupported(profileID: profileID)
        }

        let networkEndpoint = plan.hops.first?.endpoint ?? plan.target.endpoint
        let lease: any PrivateNetworkProxyLease
        do {
            lease = try await privateNetworkRegistry.openProxy(
                profileID: profileID,
                to: networkEndpoint,
                diagnostics: plan.diagnostics
            )
        } catch {
            throw SSHError.privateNetworkUnavailable(profileID: profileID, reason: error.localizedDescription)
        }

        do {
            return try await connectUsingLeaseWithRetry(
                lease,
                plan: plan,
                hostKeyPolicy: hostKeyPolicy,
                connectTimeout: CitadelConnectionPolicy.proxyConnectTimeout,
                diagnostics: plan.diagnostics
            )
        } catch {
            await lease.close()
            if let sshError = error as? SSHError { throw sshError }
            throw AuthMapping.mapConnectError(error, endpoint: plan.target.endpoint, auth: plan.target.auth)
        }
    }

    /// 私有网络刚建立时，Tailscale 本地状态可能已 Running，但到 peer 的
    /// 数据面路径还没完全就绪；首次 SSH 握手会瞬时 refused/timeout。
    /// 只对这类网络错误做有界重试，认证、指纹和配置错误立即失败。
    private func connectUsingLeaseWithRetry(
        _ lease: any PrivateNetworkProxyLease,
        plan: SSHConnectionPlan,
        hostKeyPolicy: HostKeyPolicy,
        connectTimeout: TimeAmount,
        diagnostics: ConnectionDiagnosticsContext
    ) async throws -> any SSHSession {
        var lastError: Error?
        for attempt in 1 ... ConnectionRetryPolicy.maximumAttempts {
            do {
                return try await connectUsingLease(
                    lease,
                    plan: plan,
                    hostKeyPolicy: hostKeyPolicy,
                    connectTimeout: connectTimeout,
                    diagnostics: diagnostics
                )
            } catch {
                lastError = error
                guard ConnectionRetryPolicy.isTransient(error),
                      attempt < ConnectionRetryPolicy.maximumAttempts
                else { throw error }
                try? await Task.sleep(for: ConnectionRetryPolicy.delay(afterFailedAttempt: attempt))
            }
        }
        throw lastError ?? SSHError.channelClosed
    }

    private func connectThroughExternalProxy(
        _ proxy: SSHProxyConfiguration,
        password: String?,
        plan: SSHConnectionPlan,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        guard proxy.validationError == nil else {
            throw SSHError.proxyUnavailable(reason: "invalid proxy configuration")
        }
        if proxy.authentication == .password {
            guard !proxy.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let password, !password.isEmpty
            else { throw SSHError.proxyAuthenticationFailed }
        }

        let username = proxy.username.trimmingCharacters(in: .whitespacesAndNewlines)

        let upstreamProtocol: RouteProxyProtocol
        switch proxy.kind {
        case .httpConnect:
            upstreamProtocol = .httpConnect(
                username: proxy.authentication == .password ? username : nil,
                password: proxy.authentication == .password ? password : nil
            )
        case .socks5:
            upstreamProtocol = .socks5(
                username: proxy.authentication == .password ? username : nil,
                password: proxy.authentication == .password ? password : nil
            )
        }

        let networkEndpoint = plan.hops.first?.endpoint ?? plan.target.endpoint
        let lease: any PrivateNetworkProxyLease
        let routeStarted = Date()
        do {
            lease = try await PrivateNetworkSOCKSProxy(
                upstreamHost: proxy.host.trimmingCharacters(in: .whitespacesAndNewlines),
                upstreamPort: proxy.port,
                proxyProtocol: upstreamProtocol,
                target: networkEndpoint
            ).start()
            recordPhase("route_setup", started: routeStarted, context: plan.diagnostics)
        } catch let error as SSHError {
            recordPhase("route_setup", started: routeStarted, context: plan.diagnostics, error: error)
            throw error
        } catch {
            recordPhase("route_setup", started: routeStarted, context: plan.diagnostics, error: error)
            if let proxyError = error as? PrivateNetworkError,
               proxyError == .proxyAuthenticationFailed {
                throw SSHError.proxyAuthenticationFailed
            }
            throw SSHError.proxyUnavailable(reason: error.localizedDescription)
        }

        do {
            return try await connectUsingLease(
                lease,
                plan: plan,
                hostKeyPolicy: hostKeyPolicy,
                connectTimeout: CitadelConnectionPolicy.proxyConnectTimeout,
                diagnostics: plan.diagnostics
            )
        } catch {
            await lease.close()
            if let sshError = error as? SSHError { throw sshError }
            throw AuthMapping.mapConnectError(error, endpoint: plan.target.endpoint, auth: plan.target.auth)
        }
    }

    private func connectUsingLease(
        _ lease: any PrivateNetworkProxyLease,
        plan: SSHConnectionPlan,
        hostKeyPolicy: HostKeyPolicy,
        connectTimeout: TimeAmount = CitadelConnectionPolicy.proxyConnectTimeout,
        diagnostics: ConnectionDiagnosticsContext
    ) async throws -> any SSHSession {
        let started = Date()
        do {
            if plan.hops.isEmpty {
                let client = try await connectDirect(
                    connectionEndpoint: SSHEndpoint(host: lease.endpoint.host, port: lease.endpoint.port),
                    hostKeyEndpoint: plan.target.endpoint,
                    username: plan.target.username,
                    auth: plan.target.auth,
                    hostKeyPolicy: hostKeyPolicy,
                    connectTimeout: connectTimeout
                )
                let session = CitadelSession(
                    client: client,
                    endpoint: plan.target.endpoint,
                    privateNetworkLease: lease,
                    diagnostics: diagnostics
                )
                recordPhase("ssh_handshake", started: started, context: diagnostics)
                return session
            }

            let citadelHops = plan.hops.map {
                JumpHop(endpoint: $0.endpoint, username: $0.username, auth: $0.auth)
            }
            let citadelTarget = JumpHop(
                endpoint: plan.target.endpoint,
                username: plan.target.username,
                auth: plan.target.auth
            )
            let client = try await JumpChain.connect(
                hops: citadelHops,
                target: citadelTarget,
                hostKeyStore: hostKeyStore,
                hostKeyPolicy: hostKeyPolicy,
                firstConnectionEndpoint: SSHEndpoint(host: lease.endpoint.host, port: lease.endpoint.port),
                firstConnectionTimeout: connectTimeout
            )
            let session = CitadelSession(
                client: client,
                endpoint: plan.target.endpoint,
                privateNetworkLease: lease,
                diagnostics: diagnostics
            )
            recordPhase("ssh_handshake", started: started, context: diagnostics)
            return session
        } catch {
            recordPhase("ssh_handshake", started: started, context: diagnostics, error: error)
            throw error
        }
    }

    private func recordPhase(
        _ phase: String,
        started: Date,
        context: ConnectionDiagnosticsContext,
        error: Error? = nil
    ) {
        guard let diagnosticsSink else { return }
        diagnosticsSink.record(ConnectionPhaseSample(
            context: context,
            phase: phase,
            durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            outcome: error == nil ? .success : .failure,
            errorStage: error == nil ? "" : phase,
            errorCategory: error.map(ConnectionDiagnosticsText.category) ?? "",
            errorText: error.map(ConnectionDiagnosticsText.text) ?? ""
        ))
    }

    private func connectDirect(
        connectionEndpoint: SSHEndpoint,
        hostKeyEndpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy,
        connectTimeout: TimeAmount = CitadelConnectionPolicy.tcpConnectTimeout
    ) async throws -> SSHClient {
        let method = try AuthMapping.method(for: auth, username: username)
        do {
            return try await SSHClient.connect(
                host: connectionEndpoint.host,
                port: connectionEndpoint.port,
                authenticationMethod: method,
                hostKeyValidator: CitadelHostKeyVerifier.validator(
                    endpoint: hostKeyEndpoint,
                    hostKeyStore: hostKeyStore,
                    policy: hostKeyPolicy
                ),
                reconnect: .never,
                algorithms: .all,
                connectTimeout: connectTimeout
            )
        } catch {
            throw AuthMapping.mapConnectError(error, endpoint: hostKeyEndpoint, auth: auth)
        }
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
