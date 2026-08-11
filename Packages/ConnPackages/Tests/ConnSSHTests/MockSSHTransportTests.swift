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
}
