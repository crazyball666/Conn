import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnSSHCitadel

/// 连 Spike Docker 验证 PTY shell 通道（Phase 4 核心）。
/// 门控 `CONN_SPIKE_HOST`；需 `docker compose start`。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONN_SPIKE_HOST"] != nil))
struct ShellChannelIntegrationTests {
    private var spikeHost: String {
        ProcessInfo.processInfo.environment["CONN_SPIKE_HOST"] ?? "127.0.0.1"
    }

    private func keysDir() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Spikes/S1-ssh-matrix/keys").path
    }

    private func connect() async throws -> any SSHSession {
        let pem = try String(contentsOfFile: "\(keysDir())/id_ed25519", encoding: .utf8)
        let auth = SSHAuth.key(SSHPrivateKeyMaterial(kind: .ed25519, pem: pem))
        return try await CitadelTransport(hostKeyStore: InMemoryHostKeyStore()).connect(
            SSHEndpoint(host: spikeHost, port: 2202),
            username: "deploy", auth: auth, hostKeyPolicy: .tofu
        )
    }

    @Test("开 PTY，输入命令，收到回显与输出")
    func ptyEchoesAndRunsCommand() async throws {
        let session = try await connect()
        let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))

        // 收集输出
        let collector = OutputCollector()
        let pump = Task {
            for try await chunk in channel.output {
                await collector.append(chunk)
                if await collector.text.contains("PTY_MARKER_DONE") { break }
            }
        }

        // 等 shell 提示符就绪，发一条能产出唯一标记的命令
        try await Task.sleep(for: .milliseconds(600))
        try await channel.write(Data("echo PTY_MARKER_DONE\n".utf8))

        // 等输出，最多 5s
        let deadline = Date().addingTimeInterval(5)
        while await !collector.text.contains("PTY_MARKER_DONE"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        pump.cancel()

        let text = await collector.text
        #expect(text.contains("PTY_MARKER_DONE"))

        await channel.close()
        await session.close()
    }

    @Test("resize 不抛错")
    func resizeSucceeds() async throws {
        let session = try await connect()
        let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))
        try await channel.resize(TermSize(cols: 120, rows: 40))
        await channel.close()
        await session.close()
    }
}

private actor OutputCollector {
    private var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
    // swiftlint:disable:next optional_data_string_conversion
    var text: String { String(decoding: data, as: UTF8.self) }
}
