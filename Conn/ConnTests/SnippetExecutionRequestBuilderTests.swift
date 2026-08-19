import ConnKit
import ConnRunner
import ConnSSH
import Testing
@testable import Conn

@Suite("Snippet execution request builder")
@MainActor
struct SnippetExecutionRequestBuilderTests {
    @Test("execution preparation starts on demand and builds every selected host plan")
    func preparesSelectedHostsOnDemand() async throws {
        let hosts = [host("host-a"), host("host-b")]
        let planner = makePlanner(provider: FixtureExecutionProvider())
        let snippet = Snippet(title: "Fixture", script: "echo ready")

        let result = try await SnippetExecutionRequestBuilder.prepare(
            mode: .silent,
            hosts: hosts,
            snippet: snippet,
            renderedScript: snippet.script,
            planner: planner
        )
        guard case let .ready(request) = result else {
            Issue.record("Expected execution preparation to succeed")
            return
        }

        #expect(request.hosts.map(\.id) == hosts.map(\.id))
        #expect(Set(request.plansByHostID.keys) == Set(hosts.map(\.id)))
        #expect(request.plansByHostID.values.allSatisfy {
            $0.preparedCommand == "prepared<echo ready>"
        })
    }

    @Test("dangerous batch requires exact RUN while a single host keeps simple confirmation")
    func dangerousBatchUsesTypedConfirmation() {
        #expect(!SnippetDangerConfirmationPolicy.requiresTypedConfirmation(hostCount: 1))
        #expect(SnippetDangerConfirmationPolicy.requiresTypedConfirmation(hostCount: 2))
        #expect(SnippetDangerConfirmationPolicy.accepts("RUN", hostCount: 2))
        #expect(!SnippetDangerConfirmationPolicy.accepts("run", hostCount: 2))
        #expect(!SnippetDangerConfirmationPolicy.accepts(" RUN ", hostCount: 2))
        #expect(SnippetDangerConfirmationPolicy.accepts("", hostCount: 1))
    }

    @Test("missing second-host preparation produces no request")
    func missingSecondPreparationIsAllOrNothing() async throws {
        let hosts = [host("host-a"), host("host-b")]
        let planner = makePlanner(provider: FixtureExecutionProvider())
        let firstPreparation = try await preparation(
            for: hosts[0],
            using: planner
        )
        var request: SnippetExecutionRequest?

        do {
            request = try SnippetExecutionRequestBuilder.build(
                mode: .silent,
                hosts: hosts,
                preparationByHostID: [hosts[0].id: firstPreparation],
                renderedScript: "echo ready",
                planner: planner
            )
            Issue.record("Expected the missing second-host preparation to fail planning")
        } catch {
            #expect(error is SnippetExecutionPlanningError)
        }

        #expect(request == nil)
    }

    @Test("failing second-host plan produces no request")
    func failingSecondPlanIsAllOrNothing() async throws {
        let hosts = [host("host-a"), host("host-b")]
        let planner = makePlanner(provider: FixtureExecutionProvider())
        let failingPlanner = makePlanner(
            provider: FixtureExecutionProvider(invocationError: .invocationFailed)
        )
        let preparations = [
            hosts[0].id: try await preparation(for: hosts[0], using: planner),
            hosts[1].id: try await preparation(for: hosts[1], using: failingPlanner),
        ]
        var request: SnippetExecutionRequest?

        do {
            request = try SnippetExecutionRequestBuilder.build(
                mode: .silent,
                hosts: hosts,
                preparationByHostID: preparations,
                renderedScript: "echo ready",
                planner: planner
            )
            Issue.record("Expected the second-host provider to fail planning")
        } catch {
            #expect(error as? PlanningFixtureError == .invocationFailed)
        }

        #expect(request == nil)
    }

    @Test("preparation cannot be reused after SSH connection settings change")
    func preparationRejectsChangedConnectionIdentity() async throws {
        let original = host("same-id")
        let changed = Host(
            id: original.id,
            name: original.name,
            address: "changed.example.test",
            username: original.username
        )
        let planner = makePlanner(provider: FixtureExecutionProvider())
        let originalPreparation = try await preparation(for: original, using: planner)

        #expect(throws: SnippetExecutionPlanningError.self) {
            try SnippetExecutionRequestBuilder.build(
                mode: .silent,
                hosts: [changed],
                preparationByHostID: [changed.id: originalPreparation],
                renderedScript: "echo blocked",
                planner: planner
            )
        }
    }

    @Test("silent plan and terminal route share the exact prepared command")
    func silentAndTerminalPreparedCommandsMatchWithoutRewrap() async throws {
        let host = host("host")
        let planner = makePlanner(provider: FixtureExecutionProvider())
        let preparation = try await preparation(for: host, using: planner)
        let renderedScript = "printf '%s\\n' ready"
        let arguments = (
            hosts: [host],
            preparationByHostID: [host.id: preparation],
            renderedScript: renderedScript,
            planner: planner
        )

        let silentRequest = try SnippetExecutionRequestBuilder.build(
            mode: .silent,
            hosts: arguments.hosts,
            preparationByHostID: arguments.preparationByHostID,
            renderedScript: arguments.renderedScript,
            planner: arguments.planner
        )
        let terminalRequest = try SnippetExecutionRequestBuilder.build(
            mode: .terminal,
            hosts: arguments.hosts,
            preparationByHostID: arguments.preparationByHostID,
            renderedScript: arguments.renderedScript,
            planner: arguments.planner
        )
        let silentCommand = try #require(
            silentRequest.plansByHostID[host.id]?.preparedCommand
        )
        let terminalRoute = try #require(terminalRequest.terminalRoute)

        #expect(silentCommand == "prepared<\(renderedScript)>")
        #expect(terminalRoute.preparedCommand == silentCommand)
    }

    @Test("a new execution attempt immediately clears every previous presentation")
    func newAttemptClearsPreviousPresentation() {
        var errorText: String? = "previous failure"
        var outcome: RunOutcome? = RunOutcome(
            script: "old",
            interpreter: .sh,
            exitCode: 0,
            stdout: "old output",
            stderr: ""
        )
        var batchResults = [
            ScriptBatchResult(
                hostID: "old-host",
                hostName: "old-host",
                outcome: outcome
            )
        ]

        SnippetExecutionAttemptFeedback.begin(
            errorText: &errorText,
            outcome: &outcome,
            batchResults: &batchResults
        )

        #expect(errorText == nil)
        #expect(outcome == nil)
        #expect(batchResults.isEmpty)
    }

    private func host(_ id: String) -> Host {
        Host(
            id: id,
            name: id,
            address: "\(id).example.test",
            username: "root"
        )
    }

    private func makePlanner(
        provider: any RemoteScriptExecutionProvider
    ) -> SnippetExecutionPlanner {
        let transport = MockSSHTransport(behavior: .init(dynamicResponder: { _, _ in
            .init(stdout: "/bin/sh")
        }))
        return SnippetExecutionPlanner(
            connectionManager: ConnectionManager(
                transport: transport,
                platformDetector: FixturePlatformDetector()
            ),
            executionProviderRegistry: .init(providers: [provider]),
            requirementAdapterRegistry: .init(adapters: [])
        )
    }

    private func preparation(
        for host: Host,
        using planner: SnippetExecutionPlanner
    ) async throws -> SnippetHostPreparation {
        let result = try await planner.prepare(
            snippet: Snippet(title: "Fixture", script: "echo fixture"),
            on: host
        )
        guard case let .ready(preparation) = result else {
            throw PlanningFixtureError.preparationBlocked
        }
        return preparation
    }
}

private struct FixturePlatformDetector: RemotePlatformDetecting {
    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        _ = session
        return RemotePlatformProfile(kind: .linux)
    }
}

private struct FixtureExecutionProvider: RemoteScriptExecutionProvider {
    let family = RemoteScriptFamily.posix
    let supportedPlatforms: Set<RemotePlatformKind> = [.linux]
    let supportedInterpreters: Set<ShellInterpreter> = [.sh]
    let invocationError: PlanningFixtureError?

    init(invocationError: PlanningFixtureError? = nil) {
        self.invocationError = invocationError
    }

    func interpreterProbeCommand(for interpreter: ShellInterpreter) -> String {
        "probe \(interpreter.rawValue)"
    }

    func invocation(
        for script: String,
        interpreter: ShellInterpreter
    ) throws -> String {
        _ = interpreter
        if let invocationError { throw invocationError }
        return "prepared<\(script)>"
    }
}

private enum PlanningFixtureError: Error, Equatable {
    case invocationFailed
    case preparationBlocked
}
