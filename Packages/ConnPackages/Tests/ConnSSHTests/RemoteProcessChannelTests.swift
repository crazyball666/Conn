import Foundation
import Testing
@testable import ConnSSH

@Suite("RemoteProcessChannel contracts")
struct RemoteProcessChannelTests {
    @Test("request 精确表达 direct exec 与可选 PTY")
    func requestCarriesOptionalTerminal() {
        let terminal = RemoteTerminalRequest(
            type: "xterm-256color",
            size: .init(cols: 120, rows: 40),
            modes: [.echo: 0, .canonicalInput: 1]
        )
        let withPTY = RemoteProcessRequest(command: "tmux -CC attach", terminal: terminal)
        let withoutPTY = RemoteProcessRequest(command: "cat", terminal: nil)

        #expect(withPTY.command == "tmux -CC attach")
        #expect(withPTY.terminal == terminal)
        #expect(withPTY.terminal?.modes[.echo] == 0)
        #expect(withoutPTY.terminal == nil)
    }

    @Test("terminal mode 使用 SSH opcode，保留未来扩展空间")
    func terminalModeUsesSSHOpcode() {
        #expect(RemoteTerminalMode.echo.rawValue == 53)
        #expect(RemoteTerminalMode.canonicalInput.rawValue == 51)
        #expect(RemoteTerminalMode(rawValue: 200).rawValue == 200)
    }

    @Test("stdout、stderr 与退出状态保持结构化且可比较")
    func outputAndExitAreStructuredValues() {
        let stdout = RemoteProcessOutput.stdout(Data("out".utf8))
        let stderr = RemoteProcessOutput.stderr(Data("err".utf8))
        let exit = RemoteProcessExit(exitCode: 143, signal: "TERM")

        #expect(stdout != stderr)
        #expect(exit == RemoteProcessExit(exitCode: 143, signal: "TERM"))
        #expect(RemoteProcessExit(exitCode: nil, signal: nil).exitCode == nil)
    }

    @Test("旧 transport 默认明确报告 unsupported，不回退到 shell")
    func unsupportedDefaultDoesNotFallback() async {
        let session = UnsupportedProcessSession()

        await #expect(throws: RemoteProcessError.unsupported) {
            try await session.openProcess(RemoteProcessRequest(command: "tmux", terminal: nil))
        }
        #expect(session.openShellCallCount == 0)
    }
}

private final class UnsupportedProcessSession: SSHSession, @unchecked Sendable {
    let state = AsyncStream<SSHSessionState> { continuation in continuation.finish() }
    let isConnected = true
    private(set) var openShellCallCount = 0

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        throw SSHError.channelClosed
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw SSHError.channelClosed
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        throw SSHError.channelClosed
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        openShellCallCount += 1
        throw SSHError.channelClosed
    }

    func sftp() async throws -> any RemoteFileSystem {
        throw SSHError.channelClosed
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        throw SSHError.channelClosed
    }

    func close() async {}
}
