import Foundation

/// Stable, provider-neutral identity for one ordered attachment startup stage.
/// Providers may define additional IDs without changing the terminal coordinator.
public struct TerminalStartupStageID:
    RawRepresentable,
    Hashable,
    Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public static let controlPlane: Self = "terminal.control-plane"
    public static let remoteTransport: Self = "terminal.remote-transport"
    public static let remoteProcess: Self = "terminal.remote-process"
    public static let byteTerminal: Self = "terminal.byte-terminal"
    public static let identityBinding: Self = "terminal.identity-binding"
    public static let readiness: Self = "terminal.readiness"
}

/// Preserves the failed stage while retaining the original typed error for diagnostics.
public struct TerminalStartupFailure: Error, @unchecked Sendable {
    public let stageID: TerminalStartupStageID
    public let underlyingError: any Error

    public init(
        stageID: TerminalStartupStageID,
        underlyingError: any Error
    ) {
        self.stageID = stageID
        self.underlyingError = underlyingError
    }
}

/// One resource cleanup registered only after its startup stage succeeds.
package struct TerminalStartupRollback: Sendable {
    private let operation: @Sendable () async -> Void

    package init(_ operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    fileprivate func run() async {
        await operation()
    }
}

/// A stage captures provider-owned transaction state. The generic runner only owns
/// ordering, failure attribution, cancellation, and reverse-order rollback.
package struct TerminalStartupStep: Sendable {
    package let id: TerminalStartupStageID
    private let operation: @Sendable () async throws -> TerminalStartupRollback?

    package init(
        id: TerminalStartupStageID,
        operation: @escaping @Sendable () async throws -> TerminalStartupRollback?
    ) {
        self.id = id
        self.operation = operation
    }

    fileprivate func run() async throws -> TerminalStartupRollback? {
        try await operation()
    }
}

/// Sequential startup transaction shared by persistent-terminal providers. Successful
/// completion transfers all resources to the produced attachment; any failed stage rolls
/// back every earlier resource in reverse construction order.
package struct TerminalStartupPipeline: Sendable {
    private let steps: [TerminalStartupStep]

    package init(steps: [TerminalStartupStep]) {
        self.steps = steps
    }

    package func run() async throws {
        var rollbacks: [TerminalStartupRollback] = []
        for step in steps {
            do {
                try Task.checkCancellation()
                if let rollback = try await step.run() {
                    rollbacks.append(rollback)
                }
            } catch {
                for rollback in rollbacks.reversed() {
                    await rollback.run()
                }
                if error is CancellationError {
                    throw error
                }
                throw TerminalStartupFailure(
                    stageID: step.id,
                    underlyingError: error
                )
            }
        }
    }
}
