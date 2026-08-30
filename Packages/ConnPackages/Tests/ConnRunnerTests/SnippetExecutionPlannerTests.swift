import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnRunner

@Suite("SnippetExecutionPlanner")
struct SnippetExecutionPlannerTests {
    @Test("执行准备探测脚本解释器")
    func preparationProbesScriptInterpreter() async throws {
        let commands = StringRecorder()
        let provider = FixtureScriptExecutionProvider(identifier: "linux")
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [provider],
            commandRecorder: commands
        )

        let result = try await planner.prepare(
            snippet: snippet(),
            on: host()
        )
        let preparation = try #require(readyPreparation(from: result))

        #expect(commands.values == ["probe linux sh"])
        #expect(preparation.capabilityReport[.scriptExecution] == .supported)
    }

    @Test("Windows 和 unknown 无 provider 时只报告 intrinsic blocker 且不探测 requirement")
    func unsupportedPlatformWithoutProviderDoesNotProbe() async throws {
        for kind in [RemotePlatformKind.windows, .unknown] {
            let commands = StringRecorder()
            let adapterCalls = StringRecorder()
            let adapter = FixtureRequirementAdapter(
                capability: .docker,
                resolution: .init(state: .supported, scriptPrelude: "docker-prelude"),
                recorder: adapterCalls
            )
            let planner = makePlanner(
                profile: .init(kind: kind),
                providers: [POSIXScriptExecutionProvider()],
                adapters: [adapter],
                commandRecorder: commands
            )

            let result = try await planner.prepare(
                snippet: snippet(requiredCapabilities: [.docker]),
                on: host(id: kind.rawValue, address: "192.0.2.\(kind == .windows ? 10 : 11)")
            )
            let report = try #require(blockedReport(from: result))

            #expect(report.states == [
                .scriptExecution: unsupported(.unsupportedPlatform),
            ])
            #expect(commands.values.isEmpty)
            #expect(adapterCalls.values.isEmpty)
        }
    }

    @Test("解释器探测非零报告 executableMissing 且不运行 adapters")
    func nonzeroInterpreterProbeReportsExecutableMissing() async throws {
        let commands = StringRecorder()
        let adapterCalls = StringRecorder()
        let adapter = FixtureRequirementAdapter(
            capability: .docker,
            resolution: .init(state: .supported, scriptPrelude: "unused"),
            recorder: adapterCalls
        )
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [FixtureScriptExecutionProvider(identifier: "linux")],
            adapters: [adapter],
            commandRecorder: commands,
            probeResponse: .init(stderr: "sh: not found", exitCode: 127)
        )

        let result = try await planner.prepare(
            snippet: snippet(requiredCapabilities: [.docker]),
            on: host()
        )
        let report = try #require(blockedReport(from: result))

        #expect(report.states == [
            .scriptExecution: unavailable(.executableMissing),
        ])
        #expect(commands.values == ["probe linux sh"])
        #expect(adapterCalls.values.isEmpty)
    }

    @Test("解释器探测成功但 stdout 为空白时报告 queryFailed")
    func emptyInterpreterProbeOutputReportsQueryFailed() async throws {
        for stdout in ["", " \n\t  "] {
            let adapterCalls = StringRecorder()
            let adapter = FixtureRequirementAdapter(
                capability: .docker,
                resolution: .init(state: .supported),
                recorder: adapterCalls
            )
            let planner = makePlanner(
                profile: .init(kind: .linux),
                providers: [FixtureScriptExecutionProvider(identifier: "linux")],
                adapters: [adapter],
                probeResponse: .init(stdout: stdout)
            )

            let result = try await planner.prepare(
                snippet: snippet(requiredCapabilities: [.docker]),
                on: host(id: "blank-\(stdout.count)")
            )
            let report = try #require(blockedReport(from: result))

            #expect(report.states == [
                .scriptExecution: unavailable(.queryFailed),
            ])
            #expect(adapterCalls.values.isEmpty)
        }
    }

    @Test("解释器传输错误原样传播且不伪造 capability state")
    func interpreterProbeTransportErrorPropagates() async {
        let adapterCalls = StringRecorder()
        let manager = ConnectionManager(
            transport: ExecFailingTransport(error: .channelClosed),
            platformDetector: StaticPlatformDetector(profile: .init(kind: .linux))
        )
        let planner = SnippetExecutionPlanner(
            connectionManager: manager,
            executionProviderRegistry: .init(providers: [
                FixtureScriptExecutionProvider(identifier: "linux"),
            ]),
            requirementAdapterRegistry: .init(adapters: [
                FixtureRequirementAdapter(
                    capability: .docker,
                    resolution: .init(state: .supported),
                    recorder: adapterCalls
                ),
            ])
        )

        do {
            _ = try await planner.prepare(
                snippet: snippet(requiredCapabilities: [.docker]),
                on: host()
            )
            Issue.record("Expected interpreter probe transport error")
        } catch {
            #expect(error as? SSHError == .channelClosed)
        }
        #expect(adapterCalls.values.isEmpty)
    }

    @Test("匹配 provider 且发现非空解释器路径时 scriptExecution supported")
    func matchingProviderAndDiscoveredPathAreSupported() async throws {
        let provider = FixtureScriptExecutionProvider(
            identifier: "mac",
            supportedPlatforms: [.macOS],
            supportedInterpreters: [.bash]
        )
        let planner = makePlanner(
            profile: .init(kind: .macOS),
            providers: [provider],
            probeResponse: .init(stdout: "  /opt/homebrew/bin/bash\n")
        )

        let result = try await planner.prepare(
            snippet: snippet(interpreter: .bash),
            on: host()
        )
        let preparation = try #require(readyPreparation(from: result))

        #expect(preparation.platformProfile.kind == .macOS)
        #expect(preparation.interpreter == .bash)
        #expect(preparation.resolvedInterpreterPath == "/opt/homebrew/bin/bash")
        #expect(preparation.capabilityReport[.scriptExecution] == .supported)
    }

    @Test("显式 required scriptExecution 使用 intrinsic state 且不查 adapter")
    func explicitScriptExecutionRequirementIsIntrinsic() async throws {
        let adapterCalls = StringRecorder()
        let intrinsicAdapter = FixtureRequirementAdapter(
            capability: .scriptExecution,
            resolution: .init(state: unavailable(.unknown), scriptPrelude: "must-not-run"),
            recorder: adapterCalls
        )
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [FixtureScriptExecutionProvider(identifier: "linux")],
            adapters: [intrinsicAdapter]
        )

        let result = try await planner.prepare(
            snippet: snippet(requiredCapabilities: [.scriptExecution]),
            on: host()
        )
        let preparation = try #require(readyPreparation(from: result))

        #expect(preparation.capabilityReport.states == [.scriptExecution: .supported])
        #expect(preparation.scriptPreludes.isEmpty)
        #expect(adapterCalls.values.isEmpty)
    }

    @Test("缺失或 key 不匹配的 adapter 不回退并报告 unsupported")
    func missingOrMismatchedAdapterDoesNotFallback() async throws {
        let wrongAdapterCalls = StringRecorder()
        let wrongCapabilityAdapter = FixtureRequirementAdapter(
            capability: .logs,
            resolution: .init(state: .supported, scriptPrelude: "wrong-prelude"),
            recorder: wrongAdapterCalls
        )
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [FixtureScriptExecutionProvider(identifier: "linux")],
            adapters: [wrongCapabilityAdapter]
        )

        let result = try await planner.prepare(
            snippet: snippet(requiredCapabilities: [.docker]),
            on: host()
        )
        let report = try #require(blockedReport(from: result))

        #expect(report.states == [
            .scriptExecution: .supported,
            .docker: unsupported(.unsupportedPlatform),
        ])
        #expect(wrongAdapterCalls.values.isEmpty)
    }

    @Test("duplicate adapter key 按注册顺序稳定选择第一个")
    func duplicateAdapterKeysUseFirstRegistration() async throws {
        let firstCalls = StringRecorder()
        let secondCalls = StringRecorder()
        let first = FixtureRequirementAdapter(
            capability: .docker,
            resolution: .init(state: .supported, scriptPrelude: "first-prelude"),
            recorder: firstCalls
        )
        let second = FixtureRequirementAdapter(
            capability: .docker,
            resolution: .init(state: .supported, scriptPrelude: "second-prelude"),
            recorder: secondCalls
        )
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [FixtureScriptExecutionProvider(identifier: "linux")],
            adapters: [first, second]
        )

        let result = try await planner.prepare(
            snippet: snippet(requiredCapabilities: [.docker]),
            on: host()
        )
        let preparation = try #require(readyPreparation(from: result))

        #expect(preparation.scriptPreludes == ["first-prelude"])
        #expect(firstCalls.values == [RemoteCapability.docker.rawValue])
        #expect(secondCalls.values.isEmpty)
    }

    @Test("进入 requirement 阶段后即使一项阻断也完成全部声明项")
    func requirementPhaseAggregatesAllDeclaredCapabilities() async throws {
        let callOrder = StringRecorder()
        let docker = FixtureRequirementAdapter(
            capability: .docker,
            resolution: .init(state: unavailable(.daemonNotRunning)),
            recorder: callOrder
        )
        let logs = FixtureRequirementAdapter(
            capability: .logs,
            resolution: .init(state: .supported, scriptPrelude: "logs-prelude"),
            recorder: callOrder
        )
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [FixtureScriptExecutionProvider(identifier: "linux")],
            adapters: [logs, docker]
        )

        let result = try await planner.prepare(
            snippet: snippet(requiredCapabilities: [.logs, .docker]),
            on: host()
        )
        let report = try #require(blockedReport(from: result))

        #expect(report.states == [
            .scriptExecution: .supported,
            .docker: unavailable(.daemonNotRunning),
            .logs: .supported,
        ])
        #expect(callOrder.values == [
            RemoteCapability.docker.rawValue,
            RemoteCapability.logs.rawValue,
        ])
    }

    @Test("degraded 可执行而 unavailable 和 unsupported 阻断")
    func onlyUsableCapabilityStatesProduceReadyPreparation() async throws {
        let partialIssue = CapabilityIssue(code: .partialData, fields: ["compose"])
        let cases: [(CapabilityState, Bool)] = [
            (.degraded(issues: [partialIssue]), true),
            (unavailable(.permissionDenied), false),
            (unsupported(.unsupportedPlatform), false),
        ]

        for (index, testCase) in cases.enumerated() {
            let adapter = FixtureRequirementAdapter(
                capability: .docker,
                resolution: .init(state: testCase.0, scriptPrelude: "docker-prelude"),
                recorder: StringRecorder()
            )
            let planner = makePlanner(
                profile: .init(kind: .linux),
                providers: [FixtureScriptExecutionProvider(identifier: "linux")],
                adapters: [adapter]
            )
            let result = try await planner.prepare(
                snippet: snippet(requiredCapabilities: [.docker]),
                on: host(id: "state-\(index)")
            )

            if testCase.1 {
                let preparation = try #require(readyPreparation(from: result))
                #expect(preparation.capabilityReport[.docker] == testCase.0)
                #expect(preparation.scriptPreludes == ["docker-prelude"])
            } else {
                let report = try #require(blockedReport(from: result))
                #expect(report[.docker] == testCase.0)
            }
        }
    }

    @Test("prelude 顺序按 RemoteCapability.rawValue 而非 Set 顺序")
    func preludeOrderFollowsCapabilityRawValue() async throws {
        let callOrder = StringRecorder()
        let capabilities: Set<RemoteCapability> = [.logs, .docker, .builtinCommands]
        let preludes: [RemoteCapability: String] = [
            .logs: "logs-prelude",
            .docker: "docker-prelude",
            .builtinCommands: "builtin-prelude",
        ]
        let adapters = capabilities.map { capability in
            FixtureRequirementAdapter(
                capability: capability,
                resolution: .init(state: .supported, scriptPrelude: preludes[capability]),
                recorder: callOrder
            )
        }
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [FixtureScriptExecutionProvider(identifier: "linux")],
            adapters: adapters
        )

        let result = try await planner.prepare(
            snippet: snippet(requiredCapabilities: capabilities),
            on: host()
        )
        let preparation = try #require(readyPreparation(from: result))
        let expectedCapabilities = capabilities.sorted { $0.rawValue < $1.rawValue }

        #expect(callOrder.values == expectedCapabilities.map(\.rawValue))
        #expect(preparation.scriptPreludes == expectedCapabilities.compactMap { preludes[$0] })
    }

    @Test("同一 preparation 重渲染计划不重复 SSH 或 adapter 探测")
    func rerenderingPlansDoesNotReprepareHost() async throws {
        let commands = StringRecorder()
        let adapterCalls = StringRecorder()
        let invocations = StringRecorder()
        let provider = FixtureScriptExecutionProvider(
            identifier: "linux",
            invocationRecorder: invocations
        )
        let adapter = FixtureRequirementAdapter(
            capability: .docker,
            resolution: .init(state: .supported, scriptPrelude: "docker-prelude"),
            recorder: adapterCalls
        )
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [provider],
            adapters: [adapter],
            commandRecorder: commands
        )
        let result = try await planner.prepare(
            snippet: snippet(requiredCapabilities: [.docker]),
            on: host()
        )
        let preparation = try #require(readyPreparation(from: result))

        let first = try planner.makeExecutionPlan(
            renderedScript: "echo staging",
            from: preparation
        )
        let second = try planner.makeExecutionPlan(
            renderedScript: "echo production",
            from: preparation
        )

        #expect(first.auditScript == "echo staging")
        #expect(second.auditScript == "echo production")
        #expect(first.preparedCommand != second.preparedCommand)
        #expect(commands.values == ["probe linux sh"])
        #expect(adapterCalls.values == [RemoteCapability.docker.rawValue])
        #expect(invocations.values.count == 2)
    }

    @Test("plan 分离 audit script 并只包装一次有序非空 trusted preludes")
    func executionPlanComposesTrustedPreludesExactlyOnce() async throws {
        let invocations = StringRecorder()
        let provider = FixtureScriptExecutionProvider(
            identifier: "wrapper",
            invocationRecorder: invocations
        )
        let adapters: [any SnippetRequirementAdapter] = [
            FixtureRequirementAdapter(
                capability: .docker,
                resolution: .init(
                    state: .supported,
                    scriptPrelude: "docker() { command docker \"$@\"; }"
                ),
                recorder: StringRecorder()
            ),
            FixtureRequirementAdapter(
                capability: .builtinCommands,
                resolution: .init(
                    state: .supported,
                    scriptPrelude: "PATH=/trusted:$PATH"
                ),
                recorder: StringRecorder()
            ),
            FixtureRequirementAdapter(
                capability: .logs,
                resolution: .init(state: .supported, scriptPrelude: " \n\t"),
                recorder: StringRecorder()
            ),
        ]
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [provider],
            adapters: adapters
        )
        let result = try await planner.prepare(
            snippet: snippet(requiredCapabilities: [.docker, .builtinCommands, .logs]),
            on: host()
        )
        let preparation = try #require(readyPreparation(from: result))
        let renderedScript = "echo \"$HOME\""

        let plan = try planner.makeExecutionPlan(
            renderedScript: renderedScript,
            from: preparation
        )
        let combinedScript = """
        PATH=/trusted:$PATH
        docker() { command docker "$@"; }
        echo "$HOME"
        """

        #expect(plan.auditScript == renderedScript)
        #expect(plan.preparedCommand == "wrapper<sh>[\(combinedScript)]")
        #expect(plan.interpreter == .sh)
        #expect(plan.capabilityReport == preparation.capabilityReport)
        #expect(!plan.preparedCommand.contains("set -e"))
        #expect(invocations.values == [combinedScript])
    }

    @Test("provider invocation 错误传播且不产生 partial plan")
    func providerInvocationErrorPropagates() async throws {
        let invocations = StringRecorder()
        let provider = FixtureScriptExecutionProvider(
            identifier: "failing-wrapper",
            invocationRecorder: invocations,
            invocationError: .invocationFailed
        )
        let planner = makePlanner(
            profile: .init(kind: .linux),
            providers: [provider]
        )
        let result = try await planner.prepare(snippet: snippet(), on: host())
        let preparation = try #require(readyPreparation(from: result))

        #expect(throws: FixtureError.invocationFailed) {
            _ = try planner.makeExecutionPlan(
                renderedScript: "echo never-runs",
                from: preparation
            )
        }
        #expect(invocations.values == ["echo never-runs"])
    }

    @Test("planner 用同一 atomic context 的 session 探测 profile 和解释器")
    func plannerUsesOneSessionForProfileAndInterpreterProbes() async throws {
        let detectedSessions = StringRecorder()
        let probedSessions = StringRecorder()
        let transport = IdentityTrackingTransport(probeRecorder: probedSessions)
        let manager = ConnectionManager(
            transport: transport,
            platformDetector: IdentityRecordingPlatformDetector(
                recorder: detectedSessions
            )
        )
        let host = host()
        _ = try await manager.session(for: host)
        let planner = SnippetExecutionPlanner(
            connectionManager: manager,
            executionProviderRegistry: .init(providers: [
                FixtureScriptExecutionProvider(identifier: "linux"),
            ]),
            requirementAdapterRegistry: .init(adapters: [])
        )

        let result = try await planner.prepare(snippet: snippet(), on: host)
        let preparation = try #require(readyPreparation(from: result))

        #expect(detectedSessions.values == ["session-1"])
        #expect(probedSessions.values == ["session-1"])
        #expect(preparation.platformProfile.release == "session-1")
        #expect(transport.connectCount == 1)
    }

    @Test("多主机 preparation 独立保留 profile、report、provider 和 preludes")
    func multipleHostsRetainIndependentPreparationState() async throws {
        let detector = SequentialPlatformDetector(profiles: [
            .init(kind: .linux, release: "ubuntu", architecture: "x86_64"),
            .init(kind: .macOS, release: "26", architecture: "arm64"),
        ])
        let transport = MockSSHTransport(behavior: .init(dynamicResponder: { command, _ in
            .init(stdout: command.contains("mac") ? "/bin/zsh" : "/bin/sh")
        }))
        let adapter = FixtureRequirementAdapter(
            capability: .docker,
            recorder: StringRecorder()
        ) { profile in
            if profile.kind == .linux {
                .init(state: .supported, scriptPrelude: "linux-prelude")
            } else {
                .init(
                    state: .degraded(issues: [.init(code: .partialData)]),
                    scriptPrelude: "mac-prelude"
                )
            }
        }
        let planner = SnippetExecutionPlanner(
            connectionManager: ConnectionManager(
                transport: transport,
                platformDetector: detector
            ),
            executionProviderRegistry: .init(providers: [
                FixtureScriptExecutionProvider(
                    identifier: "linux",
                    supportedPlatforms: [.linux]
                ),
                FixtureScriptExecutionProvider(
                    identifier: "mac",
                    supportedPlatforms: [.macOS]
                ),
            ]),
            requirementAdapterRegistry: .init(adapters: [adapter])
        )
        let requiredSnippet = snippet(requiredCapabilities: [.docker])

        let firstResult = try await planner.prepare(
            snippet: requiredSnippet,
            on: host(id: "linux-host", address: "192.0.2.20")
        )
        let secondResult = try await planner.prepare(
            snippet: requiredSnippet,
            on: host(id: "mac-host", address: "192.0.2.21")
        )
        let first = try #require(readyPreparation(from: firstResult))
        let second = try #require(readyPreparation(from: secondResult))
        let firstPlan = try planner.makeExecutionPlan(renderedScript: "echo first", from: first)
        let secondPlan = try planner.makeExecutionPlan(renderedScript: "echo second", from: second)

        #expect(first.platformProfile.kind == .linux)
        #expect(second.platformProfile.kind == .macOS)
        #expect(first.capabilityReport[.docker] == .supported)
        #expect(second.capabilityReport[.docker] == .degraded(
            issues: [.init(code: .partialData)]
        ))
        #expect(first.scriptPreludes == ["linux-prelude"])
        #expect(second.scriptPreludes == ["mac-prelude"])
        #expect(firstPlan.preparedCommand == "linux<sh>[linux-prelude\necho first]")
        #expect(secondPlan.preparedCommand == "mac<sh>[mac-prelude\necho second]")
    }
}

private func makePlanner(
    profile: RemotePlatformProfile,
    providers: [any RemoteScriptExecutionProvider],
    adapters: [any SnippetRequirementAdapter] = [],
    commandRecorder: StringRecorder = StringRecorder(),
    probeResponse: MockSSHTransport.CommandResponse = .init(stdout: "/bin/sh\n")
) -> SnippetExecutionPlanner {
    let transport = MockSSHTransport(behavior: .init(dynamicResponder: { command, _ in
        commandRecorder.append(command)
        return probeResponse
    }))
    return SnippetExecutionPlanner(
        connectionManager: ConnectionManager(
            transport: transport,
            platformDetector: StaticPlatformDetector(profile: profile)
        ),
        executionProviderRegistry: .init(providers: providers),
        requirementAdapterRegistry: .init(adapters: adapters)
    )
}

private func snippet(
    interpreter: ShellInterpreter = .sh,
    requiredCapabilities: Set<RemoteCapability> = []
) -> Snippet {
    Snippet(
        id: "snippet",
        title: "Fixture",
        script: "echo fixture",
        interpreter: interpreter,
        requiredCapabilities: requiredCapabilities,
        createdAt: 1
    )
}

private func host(
    id: String = "host",
    address: String = "192.0.2.1"
) -> ConnKit.Host {
    ConnKit.Host(
        id: id,
        name: id,
        address: address,
        username: "tester",
        createdAt: 1
    )
}

private func readyPreparation(
    from result: SnippetHostPreparationResult
) -> SnippetHostPreparation? {
    guard case let .ready(preparation) = result else { return nil }
    return preparation
}

private func blockedReport(
    from result: SnippetHostPreparationResult
) -> RemoteCapabilityReport? {
    guard case let .blocked(report) = result else { return nil }
    return report
}

private func unsupported(_ code: CapabilityReasonCode) -> CapabilityState {
    .unsupported(issue: .init(code: code))
}

private func unavailable(_ code: CapabilityReasonCode) -> CapabilityState {
    .unavailable(issue: .init(code: code))
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private struct StaticPlatformDetector: RemotePlatformDetecting {
    let profile: RemotePlatformProfile

    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        _ = session
        return profile
    }
}

private actor SequentialPlatformDetector: RemotePlatformDetecting {
    private var profiles: [RemotePlatformProfile]

    init(profiles: [RemotePlatformProfile]) {
        self.profiles = profiles
    }

    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        _ = session
        guard !profiles.isEmpty else { throw FixtureError.missingProfile }
        return profiles.removeFirst()
    }
}

private struct FixtureScriptExecutionProvider: RemoteScriptExecutionProvider {
    let family = RemoteScriptFamily.posix
    private let identifier: String
    private let platforms: Set<RemotePlatformKind>
    let supportedInterpreters: Set<ShellInterpreter>
    private let selectionRecorder: StringRecorder?
    private let invocationRecorder: StringRecorder?
    private let invocationError: FixtureError?

    var supportedPlatforms: Set<RemotePlatformKind> {
        selectionRecorder?.append(identifier)
        return platforms
    }

    init(
        identifier: String,
        supportedPlatforms: Set<RemotePlatformKind> = [.linux, .macOS],
        supportedInterpreters: Set<ShellInterpreter> = Set(ShellInterpreter.allCases),
        selectionRecorder: StringRecorder? = nil,
        invocationRecorder: StringRecorder? = nil,
        invocationError: FixtureError? = nil
    ) {
        self.identifier = identifier
        platforms = supportedPlatforms
        self.supportedInterpreters = supportedInterpreters
        self.selectionRecorder = selectionRecorder
        self.invocationRecorder = invocationRecorder
        self.invocationError = invocationError
    }

    func resolveExecutable(
        for interpreter: ShellInterpreter,
        on session: any SSHSession
    ) async throws -> String? {
        let probe = try await session.exec("probe \(identifier) \(interpreter.rawValue)")
        guard probe.isSuccess else { return nil }
        let path = probe.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw RemoteScriptExecutionError.invalidResolvedExecutablePath
        }
        return path
    }

    func invocation(
        for script: String,
        interpreter: ShellInterpreter,
        resolvedExecutablePath: String
    ) throws -> String {
        _ = resolvedExecutablePath
        invocationRecorder?.append(script)
        if let invocationError { throw invocationError }
        return "\(identifier)<\(interpreter.rawValue)>[\(script)]"
    }
}

private struct FixtureRequirementAdapter: SnippetRequirementAdapter {
    let capability: RemoteCapability
    let scriptFamily = RemoteScriptFamily.posix
    private let recorder: StringRecorder
    private let resolve: @Sendable (RemotePlatformProfile) -> SnippetRequirementResolution

    init(
        capability: RemoteCapability,
        resolution: SnippetRequirementResolution,
        recorder: StringRecorder
    ) {
        self.capability = capability
        self.recorder = recorder
        resolve = { _ in resolution }
    }

    init(
        capability: RemoteCapability,
        recorder: StringRecorder,
        resolve: @escaping @Sendable (RemotePlatformProfile) -> SnippetRequirementResolution
    ) {
        self.capability = capability
        self.recorder = recorder
        self.resolve = resolve
    }

    func prepare(
        on session: any SSHSession,
        profile: RemotePlatformProfile
    ) async throws -> SnippetRequirementResolution {
        _ = session
        recorder.append(capability.rawValue)
        return resolve(profile)
    }
}

private enum FixtureError: Error, Equatable {
    case invocationFailed
    case missingProfile
}

private struct IdentityRecordingPlatformDetector: RemotePlatformDetecting {
    let recorder: StringRecorder

    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        let identifier = (session as? IdentityTrackingSession)?.identifier ?? "unexpected"
        recorder.append(identifier)
        return RemotePlatformProfile(kind: .linux, release: identifier)
    }
}

private final class IdentityTrackingTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0
    private let probeRecorder: StringRecorder

    var connectCount: Int {
        lock.withLock { connections }
    }

    init(probeRecorder: StringRecorder) {
        self.probeRecorder = probeRecorder
    }

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        let connectionNumber = lock.withLock {
            connections += 1
            return connections
        }
        let identifier = "session-\(connectionNumber)"
        let base = try await MockSSHTransport(behavior: .init(dynamicResponder: { _, _ in
            .init(stdout: "/bin/sh")
        })).connect(
            endpoint,
            username: username,
            auth: auth,
            hostKeyPolicy: hostKeyPolicy
        )
        return IdentityTrackingSession(
            identifier: identifier,
            base: base,
            livenessResponses: connectionNumber == 1 ? [true, false] : [true],
            probeRecorder: probeRecorder
        )
    }
}

private final class IdentityTrackingSession: SSHSession, @unchecked Sendable {
    let identifier: String
    private let base: any SSHSession
    private let lock = NSLock()
    private var livenessResponses: [Bool]
    private let probeRecorder: StringRecorder

    init(
        identifier: String,
        base: any SSHSession,
        livenessResponses: [Bool],
        probeRecorder: StringRecorder
    ) {
        self.identifier = identifier
        self.base = base
        self.livenessResponses = livenessResponses
        self.probeRecorder = probeRecorder
    }

    var state: AsyncStream<SSHSessionState> { base.state }

    var isConnected: Bool {
        lock.withLock {
            guard !livenessResponses.isEmpty else { return base.isConnected }
            return livenessResponses.removeFirst()
        }
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        probeRecorder.append(identifier)
        return try await base.exec(command, timeout: timeout)
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        try await base.execStream(command)
    }

    func execCommandStream(
        _ command: String,
        timeout: Duration
    ) async throws -> SSHCommandStream {
        try await base.execCommandStream(command, timeout: timeout)
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        try await base.openShell(term: term)
    }

    func sftp() async throws -> any RemoteFileSystem {
        try await base.sftp()
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        try await base.openTunnel(to: target)
    }

    func close() async {
        await base.close()
    }
}

private struct ExecFailingTransport: SSHTransport {
    let error: SSHError

    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        let base = try await MockSSHTransport().connect(
            endpoint,
            username: username,
            auth: auth,
            hostKeyPolicy: hostKeyPolicy
        )
        return ExecFailingSession(base: base, error: error)
    }
}

private final class ExecFailingSession: SSHSession {
    private let base: any SSHSession
    private let error: SSHError

    init(base: any SSHSession, error: SSHError) {
        self.base = base
        self.error = error
    }

    var state: AsyncStream<SSHSessionState> { base.state }
    var isConnected: Bool { base.isConnected }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        _ = (command, timeout)
        throw error
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        try await base.execStream(command)
    }

    func execCommandStream(
        _ command: String,
        timeout: Duration
    ) async throws -> SSHCommandStream {
        try await base.execCommandStream(command, timeout: timeout)
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        try await base.openShell(term: term)
    }

    func sftp() async throws -> any RemoteFileSystem {
        try await base.sftp()
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        try await base.openTunnel(to: target)
    }

    func close() async {
        await base.close()
    }
}
