import ConnKit
import Foundation
import Testing
@testable import ConnSSH

@Suite("Remote platform detector")
struct RemotePlatformDetectorTests {
    @Test("Darwin 签名识别为 macOS")
    func detectsDarwin() {
        let profile = RemotePlatformDetector.parse("""
        __CONN_UNAME__
        Darwin
        __CONN_RELEASE__
        24.6.0
        __CONN_ARCH__
        arm64
        __CONN_SHELL__
        /bin/zsh
        __CONN_END__
        """)

        #expect(profile.kind == .macOS)
        #expect(profile.release == "24.6.0")
        #expect(profile.architecture == "arm64")
        #expect(profile.shell == .zsh)
    }

    @Test("Linux 签名识别为 Linux")
    func detectsLinux() {
        let profile = RemotePlatformDetector.parse("""
        __CONN_UNAME__
        Linux
        __CONN_RELEASE__
        6.8.0
        __CONN_ARCH__
        x86_64
        __CONN_SHELL__
        /bin/bash
        __CONN_END__
        """)

        #expect(profile == RemotePlatformProfile(
            kind: .linux,
            release: "6.8.0",
            architecture: "x86_64",
            shell: .bash
        ))
    }

    @Test("Windows 签名识别为 Windows")
    func detectsWindows() {
        let profile = RemotePlatformDetector.parse("""
        __CONN_WINDOWS__
        Microsoft Windows [Version 10.0.26100.4652]
        __CONN_ARCH__
        AMD64
        __CONN_SHELL__
        PowerShell
        __CONN_END__
        """)

        #expect(profile.kind == .windows)
        #expect(profile.release == "Microsoft Windows [Version 10.0.26100.4652]")
        #expect(profile.architecture == "AMD64")
        #expect(profile.shell == nil)
    }

    @Test("成功但未知的签名不会回退 Linux")
    func unknownStaysUnknown() {
        let profile = RemotePlatformDetector.parse("""
        __CONN_UNAME__
        Plan9
        __CONN_RELEASE__
        4e
        __CONN_END__
        """)

        #expect(profile.kind == .unknown)
        #expect(profile.release == "4e")
    }

    @Test("POSIX 探测失败后使用 Windows 探测")
    func fallsBackToWindowsProbe() async throws {
        let session = DetectorFixtureSession(responses: [
            .init(stderr: "uname: not recognized", exitCode: 127),
            .init(stdout: """
            __CONN_WINDOWS__
            Microsoft Windows [Version 11.0]
            __CONN_ARCH__
            ARM64
            __CONN_SHELL__
            PowerShell
            __CONN_END__
            """),
        ])

        let profile = try await RemotePlatformDetector().detect(on: session)

        #expect(profile.kind == .windows)
        #expect(session.commandCount == 2)
    }

    @Test("POSIX 命令成功但签名未知时仍尝试 Windows 探测")
    func successfulUnknownPOSIXProbeStillTriesWindows() async throws {
        let session = DetectorFixtureSession(responses: [
            .init(stdout: """
            __CONN_UNAME__
            __CONN_RELEASE__
            __CONN_ARCH__
            __CONN_SHELL__
            __CONN_END__
            """),
            .init(stdout: """
            __CONN_WINDOWS__
            Microsoft Windows [Version 11.0]
            __CONN_ARCH__
            AMD64
            __CONN_SHELL__
            PowerShell
            __CONN_END__
            """),
        ])

        let profile = try await RemotePlatformDetector().detect(on: session)

        #expect(profile.kind == .windows)
        #expect(session.commandCount == 2)
    }

    @Test("未知 POSIX 平台且 Windows 探测失败时保留 unknown 画像")
    func successfulUnknownPOSIXProbeRemainsUnknown() async throws {
        let session = DetectorFixtureSession(responses: [
            .init(stdout: """
            __CONN_UNAME__
            Plan9
            __CONN_RELEASE__
            4e
            __CONN_ARCH__
            amd64
            __CONN_END__
            """),
            .init(stderr: "powershell: not found", exitCode: 127),
        ])

        let profile = try await RemotePlatformDetector().detect(on: session)

        #expect(profile.kind == .unknown)
        #expect(profile.release == "4e")
        #expect(session.commandCount == 2)
    }

    @Test("两种探测都执行失败时抛探测错误")
    func throwsWhenBothProbesFail() async {
        let session = DetectorFixtureSession(responses: [
            .init(stderr: "no sh", exitCode: 127),
            .init(stderr: "no powershell", exitCode: 1),
        ])

        await #expect(throws: RemotePlatformDetectionError.self) {
            _ = try await RemotePlatformDetector().detect(on: session)
        }
    }

    @Test("Windows 探测脚本使用 EncodedCommand 避免 shell 提前展开 PowerShell 变量")
    func windowsProbeUsesEncodedCommand() {
        #expect(RemotePlatformDetector.windowsCommand.contains("-EncodedCommand"))
        #expect(!RemotePlatformDetector.windowsCommand.contains("$env:"))
        #expect(!RemotePlatformDetector.windowsCommand.contains("$ErrorActionPreference"))
    }
}

private final class DetectorFixtureSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    let isConnected = true

    private let lock = NSLock()
    private var responses: [MockSSHTransport.CommandResponse]
    private var commands: [String] = []
    private let continuation: AsyncStream<SSHSessionState>.Continuation

    init(responses: [MockSSHTransport.CommandResponse]) {
        self.responses = responses
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    var commandCount: Int {
        lock.withLock { commands.count }
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        lock.withLock { commands.append(command) }
        let response = lock.withLock { responses.isEmpty ? .init(exitCode: 127) : responses.removeFirst() }
        return ExecResult(
            exitCode: response.exitCode,
            stdout: Data(response.stdout.utf8),
            stderr: Data(response.stderr.utf8)
        )
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}
