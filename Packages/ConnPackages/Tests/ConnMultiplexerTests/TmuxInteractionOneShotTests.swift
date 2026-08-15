import ConnKit
@testable import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux one-shot terminal interaction")
struct TmuxInteractionOneShotTests {
    @Test("read-only requests remain token guarded and return exactly one bounded invocation")
    func executesGuardedReadOnlyRequest() async throws {
        let fixture = try OneShotInteractionFixture(nonce: "read-1")
        let session = InteractionSSHSession(execResult: .init(
            exitCode: 0,
            stdout: Data("__CONN_TMUX_READ_ACCEPTED_read-1__\nvalue\n".utf8),
            stderr: Data()
        ))
        let request = try TmuxControlRequest(
            renderedCommand: .init(value: "display-message -p 'value'"),
            semantics: .readOnly
        )
        let execution = try await fixture.readExecutor(session: session).execute(
            request,
            scope: fixture.scope,
            timeout: .seconds(2)
        )

        #expect(execution.output == [Data("value".utf8)])
        #expect(session.execCommands.count == 1)
        let command = try #require(session.execCommands.first)
        #expect(command.contains("#{==:#{pid},100}"))
        #expect(command.contains("#{==:#{start_time},200}"))
        #expect(command.contains("display-message -p"))
    }

    @Test("changed identity, malformed framing and output overflow fail closed")
    func rejectsUntrustedReadResponses() async throws {
        let fixture = try OneShotInteractionFixture(nonce: "read-2")
        let request = try TmuxControlRequest(
            renderedCommand: .init(value: "display-message -p 'value'"),
            semantics: .readOnly
        )
        let changed = InteractionSSHSession(execResult: .init(
            exitCode: 0,
            stdout: Data("__CONN_TMUX_READ_CHANGED_read-2__\n".utf8),
            stderr: Data()
        ))
        await #expect(throws: TmuxInteractionOneShotError.staleInstance) {
            try await fixture.readExecutor(session: changed).execute(
                request,
                scope: fixture.scope,
                timeout: .seconds(2)
            )
        }

        let malformed = InteractionSSHSession(execResult: .init(
            exitCode: 0,
            stdout: Data("ordinary output".utf8),
            stderr: Data()
        ))
        await #expect(throws: TmuxInteractionOneShotError.malformedResponse) {
            try await fixture.readExecutor(session: malformed).execute(
                request,
                scope: fixture.scope,
                timeout: .seconds(2)
            )
        }

        let oversized = InteractionSSHSession(execResult: .init(
            exitCode: 0,
            stdout: Data(repeating: 0x61, count: 9),
            stderr: Data()
        ))
        await #expect(throws: TmuxInteractionOneShotError.outputLimitExceeded(maximumBytes: 8)) {
            try await fixture.readExecutor(session: oversized, maximumBytes: 8).execute(
                request,
                scope: fixture.scope,
                timeout: .seconds(2)
            )
        }
    }

    @Test("capture-pane streams once, uses inert flags and closes at the requested byte cap")
    func streamsBoundedPaneCapture() async throws {
        let fixture = try OneShotInteractionFixture(nonce: "capture-1")
        let process = InteractionProcessChannel(outputs: [
            .stdout(Data("__CONN_TMUX_CAPTURE_ACCEPTED_capture-1__\n0123456789".utf8)),
        ])
        let session = InteractionSSHSession(process: process)
        let result = try await fixture.captureExecutor(session: session).capture(
            paneID: try #require(TmuxPaneID(rawValue: "%7")),
            startLine: -120,
            maximumBytes: 5,
            timeout: .seconds(2)
        )

        #expect(result.data == Data("01234".utf8))
        #expect(result.isTruncated)
        #expect(process.closeCount == 1)
        let request = try #require(session.processRequests.first)
        #expect(request.terminal == nil)
        #expect(request.command.contains("capture-pane -p -N -t"))
        #expect(request.command.contains("-S"))
        #expect(request.command.contains("-E"))
        #expect(!request.command.contains(" -e "))
        #expect(!request.command.contains(" -J "))
        #expect(!request.command.contains(" -M "))
    }
}

private struct OneShotInteractionFixture {
    let nonce: TmuxInvocationNonce
    let scope: TmuxOperationScope
    let runtime: PreparedRemoteScriptRuntime
    let executable: TmuxExecutablePath

    init(nonce: String) throws {
        self.nonce = try TmuxInvocationNonce(nonce)
        scope = try TmuxOperationScope(
            connectionIdentity: SSHConnectionIdentity(host: Host(
                id: "host-1",
                name: "Server",
                address: "server.example",
                username: "root"
            )),
            profileID: "profile-1",
            instanceToken: try TmuxServerInstanceToken(
                resolvedSocketPath: "/tmp/tmux/default",
                serverPID: 100,
                serverStartTime: 200
            ),
            generation: 7
        )
        runtime = try POSIXScriptExecutionProvider().prepareRuntime(
            resolvedExecutablePath: "/bin/sh",
            interpreter: .sh
        )
        executable = try TmuxExecutablePath("/usr/bin/tmux")
    }

    func readExecutor(
        session: any SSHSession,
        maximumBytes: Int = 4 * 1_024 * 1_024
    ) -> TmuxOneShotReadOnlyCommandExecutor {
        .init(
            session: session,
            runtime: runtime,
            executable: executable,
            locator: .default,
            scope: scope,
            maximumOutputBytes: maximumBytes,
            nonceFactory: { nonce }
        )
    }

    func captureExecutor(
        session: any SSHSession
    ) -> TmuxStreamingPaneHistoryCaptureExecutor {
        .init(
            session: session,
            runtime: runtime,
            executable: executable,
            locator: .default,
            scope: scope,
            nonceFactory: { nonce }
        )
    }
}

private enum InteractionTestError: Error {
    case unavailable
}

private final class InteractionSSHSession: SSHSession, @unchecked Sendable {
    private let lock = NSLock()
    private let configuredExecResult: ExecResult?
    private let configuredProcess: InteractionProcessChannel?
    private var commands: [String] = []
    private var requests: [RemoteProcessRequest] = []

    let state = AsyncStream<SSHSessionState> { $0.yield(.connected) }
    let isConnected = true

    init(execResult: ExecResult) {
        configuredExecResult = execResult
        configuredProcess = nil
    }

    init(process: InteractionProcessChannel) {
        configuredExecResult = nil
        configuredProcess = process
    }

    var execCommands: [String] { lock.withLock { commands } }
    var processRequests: [RemoteProcessRequest] { lock.withLock { requests } }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        lock.withLock { commands.append(command) }
        guard let configuredExecResult else { throw InteractionTestError.unavailable }
        return configuredExecResult
    }

    func openProcess(_ request: RemoteProcessRequest) async throws -> any RemoteProcessChannel {
        lock.withLock { requests.append(request) }
        guard let configuredProcess else { throw InteractionTestError.unavailable }
        return configuredProcess
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw InteractionTestError.unavailable
    }
    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        throw InteractionTestError.unavailable
    }
    func openShell(term: TermSize) async throws -> any ShellChannel {
        throw InteractionTestError.unavailable
    }
    func sftp() async throws -> any RemoteFileSystem { throw InteractionTestError.unavailable }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        throw InteractionTestError.unavailable
    }
    func close() async {}
}

private final class InteractionProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>
    private let lock = NSLock()
    private var closes = 0

    init(outputs: [RemoteProcessOutput]) {
        output = AsyncThrowingStream { continuation in
            for output in outputs { continuation.yield(output) }
            continuation.finish()
        }
    }

    var closeCount: Int { lock.withLock { closes } }
    func write(_ data: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func result() async throws -> RemoteProcessExit { .init(exitCode: 0, signal: nil) }
    func close() async { lock.withLock { closes += 1 } }
}
