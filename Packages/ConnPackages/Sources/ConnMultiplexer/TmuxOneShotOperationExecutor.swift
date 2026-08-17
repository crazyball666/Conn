import ConnSSH
import Foundation

package enum TmuxOneShotOperationError: Error, Sendable, Equatable {
    case invalidLimits
    case invalidTimeout
    case unsupportedRuntime(RemoteScriptFamily)
    case scopeMismatch(expected: TmuxOperationScope, actual: TmuxOperationScope)
    case staleInstance(expected: TmuxServerInstanceToken)
    case malformedResponse
    case outputLimitExceeded(maximumStdoutBytes: Int, maximumStderrBytes: Int)
    case commandRejected(exitCode: Int32, diagnostic: String)
    case outcomeUnknown
}

package struct TmuxOneShotOperationLimits: Sendable, Equatable {
    package static let `default` = Self(
        uncheckedMaximumStdoutBytes: 4 * 1_024 * 1_024,
        maximumStderrBytes: 64 * 1_024,
        maximumDiagnosticBytes: 4 * 1_024
    )

    package let maximumStdoutBytes: Int
    package let maximumStderrBytes: Int
    package let maximumDiagnosticBytes: Int

    package init(
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int,
        maximumDiagnosticBytes: Int
    ) throws {
        guard maximumStdoutBytes > 0,
              maximumStderrBytes > 0,
              maximumDiagnosticBytes > 0,
              maximumDiagnosticBytes <= maximumStderrBytes
        else {
            throw TmuxOneShotOperationError.invalidLimits
        }
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.maximumDiagnosticBytes = maximumDiagnosticBytes
    }

    private init(
        uncheckedMaximumStdoutBytes maximumStdoutBytes: Int,
        maximumStderrBytes: Int,
        maximumDiagnosticBytes: Int
    ) {
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.maximumDiagnosticBytes = maximumDiagnosticBytes
    }
}

package struct TmuxOneShotOperationResult: Sendable, Equatable {
    package let scope: TmuxOperationScope
    package let operation: TmuxOperation
    package let output: Data

    package init(scope: TmuxOperationScope, operation: TmuxOperation, output: Data) {
        self.scope = scope
        self.operation = operation
        self.output = output
    }
}

/// Executes exactly one typed mutation through one token-guarded tmux process invocation.
/// The bound scope represents the SSH connection/configuration/runtime that supplied the session.
package struct TmuxOneShotOperationExecutor: Sendable {
    package typealias NonceFactory = @Sendable () throws -> TmuxInvocationNonce

    private let session: any SSHSession
    private let runtime: PreparedRemoteScriptRuntime
    private let executable: TmuxExecutablePath
    private let locator: TmuxServerLocator
    private let scope: TmuxOperationScope
    private let limits: TmuxOneShotOperationLimits
    private let nonceFactory: NonceFactory
    private let renderer: TmuxShellInvocationRenderer

    package init(
        session: any SSHSession,
        runtime: PreparedRemoteScriptRuntime,
        executable: TmuxExecutablePath,
        locator: TmuxServerLocator,
        scope: TmuxOperationScope,
        limits: TmuxOneShotOperationLimits = .default,
        nonceFactory: @escaping NonceFactory,
        renderer: TmuxShellInvocationRenderer = .init()
    ) {
        self.session = session
        self.runtime = runtime
        self.executable = executable
        self.locator = locator
        self.scope = scope
        self.limits = limits
        self.nonceFactory = nonceFactory
        self.renderer = renderer
    }

    package func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration
    ) async throws -> TmuxOneShotOperationResult {
        guard request.scope == scope else {
            throw TmuxOneShotOperationError.scopeMismatch(
                expected: scope,
                actual: request.scope
            )
        }
        guard timeout > .zero else {
            throw TmuxOneShotOperationError.invalidTimeout
        }
        guard runtime.family == .posix else {
            throw TmuxOneShotOperationError.unsupportedRuntime(runtime.family)
        }
        try Task.checkCancellation()

        let nonce = try nonceFactory()
        let invocation = try renderer.render(
            request.operation,
            executable: executable,
            locator: locator,
            expectedInstance: scope.instanceToken,
            nonce: nonce
        )
        let command = try runtime.invocation(for: invocation.script)

        // Crossing this call is the dispatch boundary. Every thrown transport/timeout error
        // is outcome-unknown and must be reconciled, never retried by this executor.
        let execution: ExecResult
        do {
            execution = try await session.exec(command, timeout: timeout)
        } catch {
            throw TmuxOneShotOperationError.outcomeUnknown
        }

        guard execution.stdout.count <= limits.maximumStdoutBytes,
              execution.stderr.count <= limits.maximumStderrBytes
        else {
            throw TmuxOneShotOperationError.outputLimitExceeded(
                maximumStdoutBytes: limits.maximumStdoutBytes,
                maximumStderrBytes: limits.maximumStderrBytes
            )
        }

        let parsed = try parse(execution.stdout, invocation: invocation)
        switch parsed {
        case .instanceChanged:
            throw TmuxOneShotOperationError.staleInstance(expected: scope.instanceToken)
        case let .accepted(output):
            guard execution.isSuccess else {
                throw TmuxOneShotOperationError.commandRejected(
                    exitCode: execution.exitCode,
                    diagnostic: diagnostic(execution.stderr, nonce: nonce)
                )
            }
            return TmuxOneShotOperationResult(
                scope: scope,
                operation: request.operation,
                output: output
            )
        }
    }

    private enum ParsedResponse {
        case accepted(Data)
        case instanceChanged
    }

    private func parse(
        _ stdout: Data,
        invocation: TmuxShellInvocation
    ) throws -> ParsedResponse {
        let accepted = Data(invocation.guardAcceptedMarker.utf8)
        let changed = Data(invocation.instanceChangedMarker.utf8)

        if let remainder = consumeLeadingLine(accepted, from: stdout) {
            guard remainder.range(of: accepted) == nil,
                  remainder.range(of: changed) == nil
            else {
                throw TmuxOneShotOperationError.malformedResponse
            }
            return .accepted(remainder)
        }
        if let remainder = consumeLeadingLine(changed, from: stdout) {
            guard remainder.isEmpty else {
                throw TmuxOneShotOperationError.malformedResponse
            }
            return .instanceChanged
        }
        throw TmuxOneShotOperationError.malformedResponse
    }

    private func consumeLeadingLine(_ marker: Data, from output: Data) -> Data? {
        guard output.starts(with: marker) else { return nil }
        if output.count == marker.count { return Data() }

        let boundary = output.index(output.startIndex, offsetBy: marker.count)
        if output[boundary] == UInt8(ascii: "\n") {
            return Data(output[output.index(after: boundary)...])
        }
        if output[boundary] == UInt8(ascii: "\r") {
            let next = output.index(after: boundary)
            guard next < output.endIndex, output[next] == UInt8(ascii: "\n") else {
                return nil
            }
            return Data(output[output.index(after: next)...])
        }
        return nil
    }

    private func diagnostic(_ stderr: Data, nonce: TmuxInvocationNonce) -> String {
        let bounded = Data(stderr.prefix(limits.maximumDiagnosticBytes))
        return String(decoding: bounded, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
            .replacingOccurrences(of: nonce.value, with: "<redacted>")
    }
}
