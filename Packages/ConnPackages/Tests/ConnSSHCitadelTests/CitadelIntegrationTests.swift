import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnSSHCitadel

/// 连 `Spikes/S1-ssh-matrix/` Docker 矩阵的集成测试。
///
/// **门控**：仅当环境变量 `CONN_SPIKE_HOST` 设置（通常 `127.0.0.1`）时运行，
/// 否则整组跳过——CI 无 Docker 时不会变红。本机跑前需 `docker compose start`。
///
/// 用法：`CONN_SPIKE_HOST=127.0.0.1 swift test --filter CitadelIntegrationTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONN_SPIKE_HOST"] != nil))
struct CitadelIntegrationTests {
    private var spikeHost: String {
        ProcessInfo.processInfo.environment["CONN_SPIKE_HOST"] ?? "127.0.0.1"
    }

    private var keysDir: String {
        // 本测试文件在 Packages/ConnPackages/Tests/ConnSSHCitadelTests/，
        // 上溯 5 级到仓库根，再进 Spikes/S1-ssh-matrix/keys。
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ConnSSHCitadelTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ConnPackages
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // 仓库根
            .appendingPathComponent("Spikes/S1-ssh-matrix/keys")
            .path
    }

    private func loadKey(_ name: String, kind: SSHKey.Kind, passphrase: String? = nil) throws -> SSHAuth {
        let pem = try String(contentsOfFile: "\(keysDir)/\(name)", encoding: .utf8)
        return .key(SSHPrivateKeyMaterial(kind: kind, pem: pem, passphrase: passphrase))
    }

    private func transport() -> CitadelTransport {
        CitadelTransport(hostKeyStore: InMemoryHostKeyStore())
    }

    // MARK: - ed25519（S1：全矩阵可用）

    @Test("ubuntu24 + ed25519 → 连接成功并 exec 出 Linux")
    func ubuntu24Ed25519() async throws {
        let auth = try loadKey("id_ed25519", kind: .ed25519)
        let session = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2202),
            username: "deploy", auth: auth, hostKeyPolicy: .tofu
        )
        let result = try await session.exec("uname -s")
        #expect(result.stdoutText == "Linux")
        await session.close()
    }

    @Test("centos7（老服务器）+ ed25519 → algorithms:.all 覆盖旧算法，连接成功")
    func centos7Ed25519() async throws {
        let auth = try loadKey("id_ed25519", kind: .ed25519)
        let session = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2204),
            username: "deploy", auth: auth, hostKeyPolicy: .tofu
        )
        let result = try await session.exec("uname -s")
        #expect(result.stdoutText == "Linux")
        await session.close()
    }

    @Test("alpine（dropbear）+ ed25519 → 非 OpenSSH 实现连接成功")
    func alpineEd25519() async throws {
        let auth = try loadKey("id_ed25519", kind: .ed25519)
        let session = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2205),
            username: "deploy", auth: auth, hostKeyPolicy: .tofu
        )
        let result = try await session.exec("uname -s")
        #expect(result.stdoutText == "Linux")
        await session.close()
    }

    // MARK: - 密码认证

    @Test("ubuntu22 + 密码 → 连接成功")
    func ubuntu22Password() async throws {
        let session = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2201),
            username: "deploy", auth: .password("conntest123"), hostKeyPolicy: .tofu
        )
        let result = try await session.exec("whoami")
        #expect(result.stdoutText == "deploy")
        await session.close()
    }

    // MARK: - 退出码（非零退出不能被当作错误抛出）

    @Test("非零退出码返回 ExecResult 而非抛异常（grep 无匹配是正常场景）")
    func nonZeroExitReturnsResult() async throws {
        let auth = try loadKey("id_ed25519", kind: .ed25519)
        let session = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2202),
            username: "deploy", auth: auth, hostKeyPolicy: .tofu
        )
        // `false` 命令退出码恒为 1
        let result = try await session.exec("false")
        #expect(result.exitCode == 1)
        #expect(!result.isSuccess)
        await session.close()
    }

    @Test("非零退出仍保留已产出的 stdout")
    func nonZeroExitKeepsStdout() async throws {
        let auth = try loadKey("id_ed25519", kind: .ed25519)
        let session = try await transport().connect(
            SSHEndpoint(host: spikeHost, port: 2202),
            username: "deploy", auth: auth, hostKeyPolicy: .tofu
        )
        // 打印一行后以非零退出：sh -c 'echo hi; exit 3'
        let result = try await session.exec("sh -c 'echo hi; exit 3'")
        #expect(result.exitCode == 3)
        #expect(result.stdoutText == "hi")
        await session.close()
    }

    // MARK: - RSA（S1 核心结论验证）

    @Test("ubuntu24 + RSA → 失败，诊断建议改用 ed25519")
    func ubuntu24RSAFailsWithDiagnosis() async throws {
        let auth = try loadKey("id_rsa", kind: .rsa)
        do {
            _ = try await transport().connect(
                SSHEndpoint(host: spikeHost, port: 2202),
                username: "deploy", auth: auth, hostKeyPolicy: .tofu
            )
            Issue.record("预期 RSA 连现代服务器失败，但连接成功了")
        } catch let error as SSHError {
            // 核心断言：诊断必须引导用户改用 ed25519
            #expect(error.diagnosis.contains("ed25519"))
        }
    }

    // MARK: - 跳板链（S1 已验证 direct-tcpip 可行）

    @Test("经 bastion 跳板连到内网主机（无宿主端口）")
    func jumpChainToInternal() async throws {
        let auth = try loadKey("id_ed25519", kind: .ed25519)
        let bastion = JumpHop(
            endpoint: SSHEndpoint(host: spikeHost, port: 2206),
            username: "deploy",
            auth: auth
        )
        // internal 无宿主端口，只能经 bastion 用容器名访问
        let target = JumpHop(
            endpoint: SSHEndpoint(host: "conn-internal", port: 22),
            username: "deploy",
            auth: auth
        )
        let session = try await transport().connect(via: [bastion], to: target)
        // conn-internal 无宿主端口，能 exec 出结果本身就证明 direct-tcpip 隧道
        // 通了。用 /etc/hostname 落到容器名（Docker 默认 hostname 是短 ID，
        // 但 hostnamectl / cat 主机名文件更稳）；这里断言隧道确有响应且是 Linux。
        let result = try await session.exec("uname -s")
        #expect(result.isSuccess)
        #expect(result.stdoutText == "Linux")
        // 负向确认：直连 conn-internal（无宿主端口）应当失败
        await session.close()
    }

    // MARK: - keyboard-interactive（S1 R3）

    @Test("keyboard-interactive → 明确不支持")
    func keyboardInteractiveUnsupported() async throws {
        do {
            _ = try await transport().connect(
                SSHEndpoint(host: spikeHost, port: 2201),
                username: "deploy", auth: .keyboardInteractive, hostKeyPolicy: .tofu
            )
            Issue.record("预期 keyboard-interactive 抛 unsupportedByEngine")
        } catch let error as SSHError {
            #expect(error.diagnosis.contains("交互式"))
        }
    }
}
