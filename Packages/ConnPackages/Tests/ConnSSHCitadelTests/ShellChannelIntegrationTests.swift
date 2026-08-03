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

    @Test("远端 exit 后 PTY 输出流结束")
    func remoteExitFinishesOutput() async throws {
        let session = try await connect()
        let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))
        defer { Task { await session.close() } }

        let didFinish = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await _ in channel.output {}
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            try await Task.sleep(for: .milliseconds(600))
            try await channel.write(Data("exit\n".utf8))
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(didFinish)
    }

    @Test("关闭一个 PTY 不影响同一 SSH 连接上的另一个 PTY")
    func closingOnePTYKeepsAnotherPTYUsable() async throws {
        let session = try await connect()
        let first = try await session.openShell(term: TermSize(cols: 80, rows: 24))
        let second = try await session.openShell(term: TermSize(cols: 80, rows: 24))
        defer { Task { await session.close() } }

        let marker = "SECOND_PTY_STILL_OPEN"
        let markerSeen = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await chunk in second.output where String(decoding: chunk, as: UTF8.self).contains(marker) {
                    return true
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            await first.close()
            try await Task.sleep(for: .milliseconds(300))
            try await second.write(Data("echo \(marker)\n".utf8))
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(markerSeen)
        await second.close()
    }

    @Test("关闭 PTY 后写入和调整尺寸均抛出 channelClosed")
    func closedPTYRejectsWriteAndResize() async throws {
        let session = try await connect()
        let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))
        await channel.close()
        defer { Task { await session.close() } }

        do {
            try await channel.write(Data("echo should-not-write\n".utf8))
            Issue.record("已关闭的 PTY 不应允许写入")
        } catch {
            #expect(error as? SSHError == .channelClosed)
        }
        do {
            try await channel.resize(TermSize(cols: 100, rows: 30))
            Issue.record("已关闭的 PTY 不应允许 resize")
        } catch {
            #expect(error as? SSHError == .channelClosed)
        }
    }
}

private actor OutputCollector {
    private var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
    // swiftlint:disable:next optional_data_string_conversion
    var text: String { String(decoding: data, as: UTF8.self) }
}
