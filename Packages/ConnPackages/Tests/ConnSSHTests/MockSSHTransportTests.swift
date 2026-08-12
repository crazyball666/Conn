import Foundation
import Testing
import ConnKit
@testable import ConnSSH

@Suite("MockSSHTransport — 脚本化假引擎")
struct MockSSHTransportTests {
    private let endpoint = SSHEndpoint(host: "demo.local", port: 22)

    private func connect(_ transport: MockSSHTransport) async throws -> any SSHSession {
        try await transport.connect(endpoint, username: "root", auth: .password("x"), hostKeyPolicy: .tofu)
    }

    @Test("默认配置下连接成功")
    func connectsByDefault() async throws {
        let session = try await connect(MockSSHTransport())
        _ = session
    }

    @Test("注入连接拒绝 → 抛 connectionRefused")
    func injectedConnectionRefused() async throws {
        let transport = MockSSHTransport(behavior: .init(failConnect: .connectionRefused(endpoint: SSHEndpoint(
            host: "demo.local",
            port: 22
        ))))
        await #expect(throws: SSHError.self) {
            try await connect(transport)
        }
    }

    @Test("注入认证失败 → 抛 authFailed")
    func injectedAuthFailure() async throws {
        let transport = MockSSHTransport(behavior: .init(failConnect: .authFailed(reason: .badCredentials)))
        await #expect(throws: SSHError.self) {
            try await connect(transport)
        }
    }

    @Test("已知假命令返回确定性输出")
    func knownCommandDeterministicOutput() async throws {
        let session = try await connect(MockSSHTransport())
        let result = try await session.exec("uname -s")
        #expect(result.isSuccess)
        #expect(result.stdoutText == "Linux")
    }

    @Test("假引擎自身可解包解释器命令并命中内置脚本")
    func mockUnwrapsInterpreterWrapper() async throws {
        let session = try await connect(MockSSHTransport())
        let result = try await session.exec("bash -c 'uname -s'", timeout: .seconds(30))
        #expect(result.isSuccess)
        #expect(result.stdoutText == "Linux")
    }

    @Test("uptime 返回带负载的确定性行")
    func uptimeOutput() async throws {
        let session = try await connect(MockSSHTransport())
        let result = try await session.exec("uptime")
        #expect(result.stdoutText.contains("load average"))
    }

    @Test("未知命令返回 command not found 与非零退出码")
    func unknownCommandFails() async throws {
        let session = try await connect(MockSSHTransport())
        let result = try await session.exec("nonexistent_cmd_xyz")
        #expect(!result.isSuccess)
        #expect(result.stderrText.contains("not found"))
    }

    @Test("execStream 按行吐出，累加等于完整输出")
    func execStreamYieldsLines() async throws {
        let session = try await connect(MockSSHTransport())
        var collected = Data()
        for try await chunk in try await session.execStream("cat /etc/os-release") {
            collected.append(chunk)
        }
        let text = String(bytes: collected, encoding: .utf8) ?? ""
        #expect(text.contains("PRETTY_NAME"))
    }

    @Test("自定义命令响应可覆盖内置")
    func customResponseOverrides() async throws {
        var behavior = MockSSHTransport.Behavior()
        behavior.commandResponses["hostname"] = .init(stdout: "my-mock-host", exitCode: 0)
        let session = try await MockSSHTransport(behavior: behavior)
            .connect(endpoint, username: "root", auth: .password("x"), hostKeyPolicy: .tofu)
        let result = try await session.exec("hostname")
        #expect(result.stdoutText == "my-mock-host")
    }

    @Test("Mock Shell 按真实终端语义处理 Ctrl+U 清空当前输入")
    func shellClearsCurrentInput() async throws {
        let channel = MockShellChannel()
        var output = channel.output.makeAsyncIterator()
        _ = try await output.next()

        try await channel.write(Data("temporary command".utf8))
        _ = try await output.next()
        try await channel.write(Data([0x15]))

        let cleared = try #require(await output.next())
        #expect(String(decoding: cleared, as: UTF8.self) == "\r\u{1B}[2Kdemo-host:~$ ")
    }

    @Test("Mock process 精确记录 request 并保序输出 stdout/stderr 与 result")
    func processCapturesRequestOutputAndResult() async throws {
        let expectedOutput: [RemoteProcessOutput] = [
            .stdout(Data("one".utf8)),
            .stderr(Data("two".utf8)),
            .stdout(Data("three".utf8)),
        ]
        let expectedExit = RemoteProcessExit(exitCode: 7, signal: nil)
        var behavior = MockSSHTransport.Behavior()
        behavior.processResponses["tmux -CC"] = .init(
            outputs: expectedOutput,
            exit: expectedExit
        )
        let session = try await connect(MockSSHTransport(behavior: behavior))
        let request = RemoteProcessRequest(
            command: "tmux -CC",
            terminal: .init(type: "xterm-256color", size: .init(cols: 80, rows: 24))
        )

        let channel = try await session.openProcess(request)
        var received: [RemoteProcessOutput] = []
        for try await output in channel.output {
            received.append(output)
        }

        #expect(received == expectedOutput)
        #expect(try await channel.result() == expectedExit)
        let mock = try #require(channel as? MockRemoteProcessChannel)
        #expect(mock.request == request)
    }

    @Test("长驻 Mock process 可写 stdin、调整 PTY 并显式完成")
    func processSupportsWriteResizeAndCompletion() async throws {
        var behavior = MockSSHTransport.Behavior()
        behavior.processResponses["persistent"] = .init(keepsOpen: true)
        let session = try await connect(MockSSHTransport(behavior: behavior))
        let channel = try await session.openProcess(.init(
            command: "persistent",
            terminal: .init(type: "xterm", size: .init(cols: 80, rows: 24))
        ))
        let mock = try #require(channel as? MockRemoteProcessChannel)

        try await channel.write(Data("command\n".utf8))
        try await channel.resize(.init(cols: 120, rows: 40))
        await mock.complete(.init(exitCode: 0, signal: nil))

        #expect(await mock.recordedWrites() == [Data("command\n".utf8)])
        #expect(await mock.recordedSizes() == [.init(cols: 120, rows: 40)])
        #expect(try await channel.result() == .init(exitCode: 0, signal: nil))
    }

    @Test("无 PTY 的 process 明确拒绝 resize")
    func processRejectsResizeWithoutTerminal() async throws {
        var behavior = MockSSHTransport.Behavior()
        behavior.processResponses["no-pty"] = .init(keepsOpen: true)
        let session = try await connect(MockSSHTransport(behavior: behavior))
        let channel = try await session.openProcess(.init(command: "no-pty"))

        await #expect(throws: RemoteProcessError.terminalNotAllocated) {
            try await channel.resize(.init(cols: 120, rows: 40))
        }
        await channel.close()
    }

    @Test("process close 幂等且不关闭共享 SSH session")
    func processCloseIsIdempotentAndSessionSurvives() async throws {
        var behavior = MockSSHTransport.Behavior()
        behavior.processResponses["persistent"] = .init(keepsOpen: true)
        let session = try await connect(MockSSHTransport(behavior: behavior))
        let channel = try await session.openProcess(.init(command: "persistent"))
        let mock = try #require(channel as? MockRemoteProcessChannel)

        await channel.close()
        await channel.close()

        #expect(await mock.closeCount() == 1)
        await #expect(throws: SSHError.channelClosed) {
            try await channel.result()
        }
        #expect(try await session.exec("uname -s").stdoutText == "Linux")
    }
}
