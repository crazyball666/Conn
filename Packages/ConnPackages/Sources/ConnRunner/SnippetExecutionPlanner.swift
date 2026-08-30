import ConnKit
import ConnSSH
import Foundation

/// Prepares one snippet requirement for a specific remote-script family.
public protocol SnippetRequirementAdapter: Sendable {
    var capability: RemoteCapability { get }
    var scriptFamily: RemoteScriptFamily { get }

    func prepare(
        on session: any SSHSession,
        profile: RemotePlatformProfile
    ) async throws -> SnippetRequirementResolution
}

/// The observed capability state and optional trusted script bootstrap produced by an adapter.
public struct SnippetRequirementResolution: Sendable, Equatable {
    public let state: CapabilityState
    public let scriptPrelude: String?

    public init(
        state: CapabilityState,
        scriptPrelude: String? = nil
    ) {
        self.state = state
        self.scriptPrelude = scriptPrelude
    }
}

/// Selects requirement adapters by capability and remote-script family.
public struct SnippetRequirementAdapterRegistry: Sendable {
    private struct Key: Sendable, Hashable {
        let capability: RemoteCapability
        let scriptFamily: RemoteScriptFamily
    }

    private let adapters: [Key: any SnippetRequirementAdapter]

    /// Registers adapters in priority order. For a duplicate capability/family key,
    /// the first registered adapter wins deterministically.
    public init(adapters: [any SnippetRequirementAdapter]) {
        var indexed: [Key: any SnippetRequirementAdapter] = [:]
        for adapter in adapters {
            let key = Key(
                capability: adapter.capability,
                scriptFamily: adapter.scriptFamily
            )
            if indexed[key] == nil {
                indexed[key] = adapter
            }
        }
        self.adapters = indexed
    }

    public func adapter(
        for capability: RemoteCapability,
        scriptFamily: RemoteScriptFamily
    ) -> (any SnippetRequirementAdapter)? {
        adapters[Key(capability: capability, scriptFamily: scriptFamily)]
    }
}

/// Immutable, host-specific output of all network-backed snippet preparation.
///
/// It intentionally retains only stable values and the selected stateless execution
/// provider. SSH sessions and feature-specific runtime types remain outside this value.
public struct SnippetHostPreparation: Sendable {
    public let connectionIdentity: SSHConnectionIdentity
    public let platformProfile: RemotePlatformProfile
    public let capabilityReport: RemoteCapabilityReport
    public let scriptPreludes: [String]
    public let interpreter: ShellInterpreter
    public let resolvedInterpreterPath: String
    public let executionProvider: any RemoteScriptExecutionProvider

    init(
        connectionIdentity: SSHConnectionIdentity,
        platformProfile: RemotePlatformProfile,
        capabilityReport: RemoteCapabilityReport,
        scriptPreludes: [String],
        interpreter: ShellInterpreter,
        resolvedInterpreterPath: String,
        executionProvider: any RemoteScriptExecutionProvider
    ) {
        self.connectionIdentity = connectionIdentity
        self.platformProfile = platformProfile
        self.capabilityReport = capabilityReport
        self.scriptPreludes = scriptPreludes
        self.interpreter = interpreter
        self.resolvedInterpreterPath = resolvedInterpreterPath
        self.executionProvider = executionProvider
    }
}

/// A pure execution artifact that separates audit text from the remote command.
public struct SnippetExecutionPlan: Sendable, Equatable {
    public let connectionIdentity: SSHConnectionIdentity
    public let auditScript: String
    public let preparedCommand: String
    public let interpreter: ShellInterpreter
    public let capabilityReport: RemoteCapabilityReport

    init(
        connectionIdentity: SSHConnectionIdentity,
        auditScript: String,
        preparedCommand: String,
        interpreter: ShellInterpreter,
        capabilityReport: RemoteCapabilityReport
    ) {
        self.connectionIdentity = connectionIdentity
        self.auditScript = auditScript
        self.preparedCommand = preparedCommand
        self.interpreter = interpreter
        self.capabilityReport = capabilityReport
    }
}

public enum SnippetHostPreparationResult: Sendable {
    case ready(SnippetHostPreparation)
    case blocked(RemoteCapabilityReport)
}

/// Probes host readiness once, then creates any number of pure execution plans.
public struct SnippetExecutionPlanner: Sendable {
    private let connectionManager: ConnectionManager
    private let executionProviderRegistry: RemoteScriptExecutionProviderRegistry
    private let requirementAdapterRegistry: SnippetRequirementAdapterRegistry

    public init(
        connectionManager: ConnectionManager,
        executionProviderRegistry: RemoteScriptExecutionProviderRegistry,
        requirementAdapterRegistry: SnippetRequirementAdapterRegistry
    ) {
        self.connectionManager = connectionManager
        self.executionProviderRegistry = executionProviderRegistry
        self.requirementAdapterRegistry = requirementAdapterRegistry
    }

    public func prepare(
        snippet: Snippet,
        on host: ConnKit.Host
    ) async throws -> SnippetHostPreparationResult {
        let platformContext = try await connectionManager.platformContext(for: host)
        let session = platformContext.session
        let profile = platformContext.profile

        guard let executionProvider = executionProviderRegistry.provider(
            for: profile.kind,
            interpreter: snippet.interpreter
        ) else {
            return blockedScriptExecution(reason: .unsupportedPlatform)
        }

        let discoveredPath: String?
        do {
            discoveredPath = try await executionProvider.resolveExecutable(
                for: snippet.interpreter,
                on: session
            )
        } catch RemoteScriptExecutionError.invalidResolvedExecutablePath {
            return blockedScriptExecution(
                state: .unavailable(issue: .init(code: .queryFailed))
            )
        } catch is RemoteExecutableResolutionError {
            return blockedScriptExecution(
                state: .unavailable(issue: .init(code: .queryFailed))
            )
        }
        guard let discoveredPath else {
            return blockedScriptExecution(
                state: .unavailable(issue: .init(code: .executableMissing))
            )
        }
        guard !discoveredPath.isEmpty else {
            return blockedScriptExecution(
                state: .unavailable(issue: .init(code: .queryFailed))
            )
        }

        var states: [RemoteCapability: CapabilityState] = [
            .scriptExecution: .supported,
        ]
        var scriptPreludes: [String] = []
        var hasBlocker = false
        let requirements = snippet.requiredCapabilities
            .filter { $0 != .scriptExecution }
            .sorted { $0.rawValue < $1.rawValue }

        for capability in requirements {
            guard let adapter = requirementAdapterRegistry.adapter(
                for: capability,
                scriptFamily: executionProvider.family
            ) else {
                states[capability] = .unsupported(
                    issue: .init(code: .unsupportedPlatform)
                )
                hasBlocker = true
                continue
            }

            let resolution = try await adapter.prepare(on: session, profile: profile)
            states[capability] = resolution.state
            if resolution.state.isUsableForSnippetExecution {
                if let scriptPrelude = resolution.scriptPrelude {
                    scriptPreludes.append(scriptPrelude)
                }
            } else {
                hasBlocker = true
            }
        }

        let report = RemoteCapabilityReport(states: states)
        guard !hasBlocker else { return .blocked(report) }
        return .ready(SnippetHostPreparation(
            connectionIdentity: SSHConnectionIdentity(host: host),
            platformProfile: profile,
            capabilityReport: report,
            scriptPreludes: scriptPreludes,
            interpreter: snippet.interpreter,
            resolvedInterpreterPath: discoveredPath,
            executionProvider: executionProvider
        ))
    }

    public func makeExecutionPlan(
        renderedScript: String,
        from preparation: SnippetHostPreparation
    ) throws -> SnippetExecutionPlan {
        let nonemptyPreludes = preparation.scriptPreludes.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let preparedScript = (nonemptyPreludes + [renderedScript])
            .joined(separator: "\n")
        let preparedCommand = try preparation.executionProvider.invocation(
            for: preparedScript,
            interpreter: preparation.interpreter,
            resolvedExecutablePath: preparation.resolvedInterpreterPath
        )
        return SnippetExecutionPlan(
            connectionIdentity: preparation.connectionIdentity,
            auditScript: renderedScript,
            preparedCommand: preparedCommand,
            interpreter: preparation.interpreter,
            capabilityReport: preparation.capabilityReport
        )
    }

    private func blockedScriptExecution(
        reason: CapabilityReasonCode
    ) -> SnippetHostPreparationResult {
        blockedScriptExecution(
            state: .unsupported(issue: .init(code: reason))
        )
    }

    private func blockedScriptExecution(
        state: CapabilityState
    ) -> SnippetHostPreparationResult {
        .blocked(RemoteCapabilityReport(states: [.scriptExecution: state]))
    }
}

private extension CapabilityState {
    var isUsableForSnippetExecution: Bool {
        switch self {
        case .supported, .degraded:
            true
        case .unavailable, .unsupported:
            false
        }
    }
}
