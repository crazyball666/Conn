import ConnKit
import ConnRunner
import ConnSSH
import Testing
@testable import Conn

@Suite("Snippet execution request builder")
@MainActor
struct SnippetExecutionRequestBuilderTests {
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

    @Test("a new valid planning attempt clears a stale error")
    func validAttemptClearsStaleError() {
        var errorText: String? = "previous failure"

        SnippetExecutionAttemptFeedback.begin(errorText: &errorText)

        #expect(errorText == nil)
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
