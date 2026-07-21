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
        _ = hostKeyPolicy

        do {
            let client = try await SSHClient.connect(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: method,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                algorithms: .all
            )
            return CitadelSession(client: client)
        } catch {
            throw AuthMapping.mapConnectError(error, endpoint: endpoint, auth: auth)
        }
    }
}
