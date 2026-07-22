import ConnCrypto
import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnSSHCitadel

/// 端到端验证密钥编码：生成 ed25519 → 部署公钥 → 用生成的私钥登录。
///
/// OpenSSH 服务器接受该公钥并允许登录，就证明公钥 wire 编码与私钥原始表示
/// 全链路正确。门控 `CONN_SPIKE_HOST`；需 `docker compose start`。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONN_SPIKE_HOST"] != nil))
struct GeneratedKeyIntegrationTests {
    private var spikeHost: String {
        ProcessInfo.processInfo.environment["CONN_SPIKE_HOST"] ?? "127.0.0.1"
    }

    private func transport() -> CitadelTransport {
        CitadelTransport(hostKeyStore: InMemoryHostKeyStore())
    }

    @Test("生成密钥 → 部署公钥 → 用生成的私钥免密登录（ubuntu24）")
    func generateDeployLogin() async throws {
        // 1. 生成一把全新 ed25519
        let generated = SSHKeyGenerator.generateEd25519(comment: "conn-test@integration")

        // 2. 用密码登录，把公钥追加进 deploy 用户的 authorized_keys（幂等）
        let passwordSession = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2202),
            username: "deploy", auth: .password("conntest123"), hostKeyPolicy: .tofu
        )
        let deployCommand = """
        mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
        grep -qF '\(generated.publicKeyOpenSSH)' ~/.ssh/authorized_keys || \
        echo '\(generated.publicKeyOpenSSH)' >> ~/.ssh/authorized_keys
        """
        let deployResult = try await passwordSession.exec(deployCommand)
        #expect(deployResult.isSuccess)
        await passwordSession.close()

        // 3. 用生成的私钥（原始表示）登录——不带密码
        let keyAuth = SSHAuth.key(SSHPrivateKeyMaterial(kind: .ed25519, raw: generated.privateKeyRaw))
        let keySession = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2202),
            username: "deploy", auth: keyAuth, hostKeyPolicy: .tofu
        )
        let whoami = try await keySession.exec("whoami")
        #expect(whoami.stdoutText == "deploy")
        await keySession.close()

        // 4. 清理：移除刚部署的公钥
        let cleanupSession = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2202),
            username: "deploy", auth: .password("conntest123"), hostKeyPolicy: .tofu
        )
        _ = try? await cleanupSession.exec(
            "grep -vF '\(generated.publicKeyOpenSSH)' ~/.ssh/authorized_keys > ~/.ssh/ak.tmp && mv ~/.ssh/ak.tmp ~/.ssh/authorized_keys"
        )
        await cleanupSession.close()
    }
}
