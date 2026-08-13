import ConnKit
@testable import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux guarded one-shot operation executor")
struct TmuxOneShotOperationExecutorTests {
    @Test("guard acceptance returns bounded ordinary output through one prepared POSIX invocation")
    func executesAcceptedOperation() async throws {
        let fixture = try OneShotFixture()
        let stdout = Data("\(fixture.acceptedMarker)\n@2\n".utf8)
        let session = OneShotSSHSession(result: .success(.init(
            exitCode: 0,
            stdout: stdout,
            stderr: Data()
        )))
        let executor = fixture.executor(session: session)

        let result = try await executor.execute(fixture.request, timeout: .seconds(20))

        #expect(result.scope == fixture.scope)
        #expect(result.operation == fixture.operation)
        #expect(result.output == Data("@2\n".utf8))
        let invocations = session.invocations
        #expect(invocations.count == 1)
        #expect(invocations[0].timeout == .seconds(20))
        #expect(invocations[0].command.hasPrefix("/bin/sh -c "))
        #expect(invocations[0].command.contains("/usr/bin/tmux"))
    }

    @Test("instance-changed marker is a structured stale-instance result")
    func rejectsChangedInstance() async throws {
        let fixture = try OneShotFixture()
        let session = OneShotSSHSession(result: .success(.init(
            exitCode: 0,
            stdout: Data("\(fixture.changedMarker)\n".utf8),
            stderr: Data()
        )))

        await #expect(throws: TmuxOneShotOperationError.staleInstance(
            expected: fixture.scope.instanceToken
        )) {
            try await fixture.executor(session: session).execute(
                fixture.request,
                timeout: .seconds(20)
            )
        }
        #expect(session.invocations.count == 1)
    }

    @Test("a returned nonzero exit is rejected once and redacts invocation nonce")
    func reportsKnownRejection() async throws {
        let fixture = try OneShotFixture()
        let session = OneShotSSHSession(result: .success(.init(
            exitCode: 1,
            stdout: Data("\(fixture.acceptedMarker)\n".utf8),
            stderr: Data("target failed for one-shot-1\n".utf8)
        )))

        await #expect(throws: TmuxOneShotOperationError.commandRejected(
            exitCode: 1,
            diagnostic: "target failed for <redacted>"
        )) {
            try await fixture.executor(session: session).execute(
                fixture.request,
                timeout: .seconds(20)
            )
        }
        #expect(session.invocations.count == 1)
    }

    @Test("transport failure after exec entry is outcome unknown and is never replayed")
    func quarantinesTransportFailure() async throws {
        let fixture = try OneShotFixture()
        let session = OneShotSSHSession(result: .failure(.transportLost))

        await #expect(throws: TmuxOneShotOperationError.outcomeUnknown) {
            try await fixture.executor(session: session).execute(
                fixture.request,
                timeout: .seconds(20)
            )
        }
        #expect(session.invocations.count == 1)
    }

    @Test("scope mismatch and invalid timeout fail before SSH dispatch")
    func validatesBeforeDispatch() async throws {
        let fixture = try OneShotFixture()
        let session = OneShotSSHSession(result: .success(.init(
            exitCode: 0,
            stdout: Data("\(fixture.acceptedMarker)\n".utf8),
            stderr: Data()
        )))
        let executor = fixture.executor(session: session)
        let otherScope = try fixture.scope(generation: 8)
        let otherRequest = TmuxOperationRequest(scope: otherScope, operation: fixture.operation)

        await #expect(throws: TmuxOneShotOperationError.scopeMismatch(
            expected: fixture.scope,
            actual: otherScope
        )) {
            try await executor.execute(otherRequest, timeout: .seconds(20))
        }
        await #expect(throws: TmuxOneShotOperationError.invalidTimeout) {
            try await executor.execute(fixture.request, timeout: .zero)
        }
        #expect(session.invocations.isEmpty)
    }

    @Test("missing, conflicting, and oversized markers fail closed without another invocation")
    func rejectsMalformedResults() async throws {
        let fixture = try OneShotFixture()
        let malformed = OneShotSSHSession(result: .success(.init(
            exitCode: 0,
            stdout: Data("ordinary output\n".utf8),
            stderr: Data()
        )))
        await #expect(throws: TmuxOneShotOperationError.malformedResponse) {
            try await fixture.executor(session: malformed).execute(
                fixture.request,
                timeout: .seconds(20)
            )
        }
        #expect(malformed.invocations.count == 1)

        let limits = try TmuxOneShotOperationLimits(
            maximumStdoutBytes: 8,
            maximumStderrBytes: 8,
            maximumDiagnosticBytes: 4
        )
        let oversized = OneShotSSHSession(result: .success(.init(
            exitCode: 0,
            stdout: Data(repeating: 0x61, count: 9),
            stderr: Data()
        )))
        await #expect(throws: TmuxOneShotOperationError.outputLimitExceeded(
            maximumStdoutBytes: 8,
            maximumStderrBytes: 8
        )) {
            try await fixture.executor(session: oversized, limits: limits).execute(
                fixture.request,
                timeout: .seconds(20)
            )
        }
        #expect(oversized.invocations.count == 1)
    }
}

private struct OneShotFixture: Sendable {
    let nonce: TmuxInvocationNonce
    let scope: TmuxOperationScope
    let operation: TmuxOperation
    let request: TmuxOperationRequest
    let runtime: PreparedRemoteScriptRuntime
    let executable: TmuxExecutablePath
    let locator = TmuxServerLocator.default

    init() throws {
        nonce = try TmuxInvocationNonce("one-shot-1")
        scope = try Self.makeScope(generation: 7)
        operation = .createWindow(
            in: try #require(TmuxSessionID(rawValue: "$1")),
            name: try TmuxName("editor")
        )
        request = TmuxOperationRequest(scope: scope, operation: operation)
        runtime = try POSIXScriptExecutionProvider().prepareRuntime(
            resolvedExecutablePath: "/bin/sh",
            interpreter: .sh
        )
        executable = try TmuxExecutablePath("/usr/bin/tmux")
    }

    var acceptedMarker: String {
        "__CONN_TMUX_GUARD_ACCEPTED_\(nonce.value)__"
    }

    var changedMarker: String {
        "__CONN_TMUX_INSTANCE_CHANGED_\(nonce.value)__"
    }

    func scope(generation: UInt64) throws -> TmuxOperationScope {
        try Self.makeScope(generation: generation)
    }

    func executor(
        session: any SSHSession,
        limits: TmuxOneShotOperationLimits = .default
    ) -> TmuxOneShotOperationExecutor {
        TmuxOneShotOperationExecutor(
            session: session,
            runtime: runtime,
            executable: executable,
            locator: locator,
            scope: scope,
            limits: limits,
            nonceFactory: { nonce }
        )
    }

    private static func makeScope(generation: UInt64) throws -> TmuxOperationScope {
        try TmuxOperationScope(
            connectionIdentity: SSHConnectionIdentity(host: Host(
                id: "host-1",
                name: "Server",
                address: "server.example",
                username: "root"
            )),
            profileID: "profile-1",
            instanceToken: TmuxServerInstanceToken(
                resolvedSocketPath: "/tmp/tmux/default",
                serverPID: 100,
                serverStartTime: 200
            ),
            generation: generation
        )
    }
}

private enum OneShotTestError: Error {
    case transportLost
}

private struct OneShotInvocation: Sendable, Equatable {
    let command: String
    let timeout: Duration
}

private final class OneShotSSHSession: SSHSession, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<ExecResult, OneShotTestError>
    private var recordedInvocations: [OneShotInvocation] = []

    let state = AsyncStream<SSHSessionState> { continuation in
        continuation.yield(.connected)
    }
    let isConnected = true

    init(result: Result<ExecResult, OneShotTestError>) {
        self.result = result
    }

    var invocations: [OneShotInvocation] {
        lock.withLock { recordedInvocations }
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        try lock.withLock {
            recordedInvocations.append(.init(command: command, timeout: timeout))
            return try result.get()
        }
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw OneShotTestError.transportLost
    }

    func execCommandStream(
        _ command: String,
        timeout: Duration
    ) async throws -> SSHCommandStream {
        throw OneShotTestError.transportLost
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        throw OneShotTestError.transportLost
    }

    func sftp() async throws -> any RemoteFileSystem {
        throw OneShotTestError.transportLost
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        throw OneShotTestError.transportLost
    }

    func close() async {}
}
