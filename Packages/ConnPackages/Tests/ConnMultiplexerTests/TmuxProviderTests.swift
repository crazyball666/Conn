import ConnKit
import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("Tmux provider")
struct TmuxProviderTests {
    @Test("静态 probe 在 Linux 上固定绝对路径并绑定 server identity")
    func probeResolvesRuntimeAndInstance() async throws {
        let context = try await makeContext(behavior: behavior())
        let availability = try await TmuxProvider().probe(in: context)

        #expect(availability.state == .available)
        #expect(availability.effectiveFeatures.contains(.workspaceDiscovery))
        #expect(!availability.effectiveFeatures.contains(.eventStreaming))

        let instance = try #require(availability.instance)
        let payload = try JSONDecoder().decode(
            TmuxWorkspaceInstancePayload.self,
            from: instance.providerPayload
        )
        #expect(payload.serverInstanceToken.serverPID == 1234)
        #expect(payload.serverInstanceToken.serverStartTime == 987654)
        #expect(payload.serverInstanceToken.resolvedSocketPath == "/tmp/tmux-1000/default")
    }

    @Test("无 server 时允许创建/发现能力，但不伪造 instance")
    func probeDistinguishesAbsentServer() async throws {
        let context = try await makeContext(behavior: behavior(serverRunning: false))
        let availability = try await TmuxProvider().probe(in: context)

        #expect(availability.state == .degraded)
        #expect(availability.instance == nil)
        #expect(availability.issue == .serverUnavailable)
        #expect(availability.effectiveFeatures == [.workspaceDiscovery, .workspaceCreation])
    }

    @Test("首次创建在单次 bootstrap invocation 内返回 session 与 server token")
    func bootstrapReturnsAtomicWorkspaceIdentity() async throws {
        let context = try await makeContext(behavior: behavior(serverRunning: false))
        let workspace = try await TmuxProvider().createWorkspace(
            CreateWorkspaceRequest(name: "first"),
            in: context
        )
        #expect(workspace.workspaceID == "$1")
        let payload = try JSONDecoder().decode(
            TmuxWorkspaceInstancePayload.self,
            from: workspace.providerInstancePayload
        )
        #expect(payload.serverInstanceToken.serverPID == 1234)
    }

    @Test("tmux 不存在时返回 unavailable，而不是回退到登录 shell")
    func probeReportsMissingTmux() async throws {
        let context = try await makeContext(behavior: behavior(tmuxInstalled: false))
        let availability = try await TmuxProvider().probe(in: context)

        #expect(availability.state == .unavailable)
        #expect(availability.issue == .executableMissing)
    }

    @Test("Windows 直接 unsupported，完全不执行 POSIX probe")
    func windowsDoesNotRunPOSIXProbe() async throws {
        let profile = makeProfile()
        let host = Host(id: "host-1", name: "Windows", address: "win.local", username: "tester")
        // The platform context itself needs a live session. A normal mock is used here;
        // the provider must return before it can issue any command.
        let remote = try await ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector(kind: .windows)
        ).platformContext(for: host)
        let context = try PersistentTerminalContext(platformContext: remote, backendProfile: profile)
        let availability = try await TmuxProvider().probe(in: context)

        #expect(availability.state == .unsupported)
        #expect(availability.issue == .unsupportedPlatform)
    }

    @Test("配置 key 与 locator 不一致时拒绝 profile")
    func profileLocatorMismatchIsRejected() async throws {
        let context = try await makeContext(
            behavior: behavior(),
            profile: makeProfile(configurationKey: "named:wrong")
        )

        await #expect(throws: PersistentTerminalError.invalidConfiguration) {
            try await TmuxProvider().probe(in: context)
        }
    }

    @Test("listWorkspaces 使用独立安全字段并生成可重连 workspace descriptor")
    func listsWorkspacesWithInstancePayload() async throws {
        let context = try await makeContext(behavior: behavior(sessionID: "$7", sessionName: "ops"))
        let workspaces = try await TmuxProvider().listWorkspaces(in: context)

        let workspace = try #require(workspaces.first)
        #expect(workspace.name == "ops")
        #expect(workspace.workspace.workspaceID == "$7")
        let payload = try JSONDecoder().decode(
            TmuxWorkspaceInstancePayload.self,
            from: workspace.workspace.providerInstancePayload
        )
        #expect(payload.serverInstanceToken.serverPID == 1234)
    }

    @Test("openAttachment 走 RemoteProcessChannel 并保留 descriptor 生命周期")
    func opensPassthroughAttachmentThroughProcessChannel() async throws {
        let recorder = ProcessRequestRecorder()
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            await recorder.record(request)
            if request.command.contains("-CC") {
                let nonce = request.command
                    .components(separatedBy: "nonce=")
                    .last?
                    .split(whereSeparator: { $0 == " " || $0 == "'" })
                    .first
                    .map(String.init) ?? "test"
                return RecordingProcessChannel(
                    outputs: [.stdout(Data(
                        "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p\u{1B}".utf8
                    ))]
                )
            }
            let marker = "nonce="
            let nonce = request.command
                .components(separatedBy: marker)
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            return RecordingProcessChannel(
                outputs: [.stdout(Data("__CONN_TMUX_ATTACH_v1__ nonce=\(nonce) tty=/dev/pts/1 pid=100\n".utf8))]
            )
        }
        let context = try await makeContext(
            behavior: behavior(processFactory: processFactory)
        )
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux-1000/default",
            serverPID: 1234,
            serverStartTime: 987654
        )
        let workspace = RemoteWorkspaceRef(
            workspaceID: "$1",
            instancePayloadVersion: 1,
            providerInstancePayload: try JSONEncoder().encode(
                TmuxWorkspaceInstancePayload(serverInstanceToken: token)
            )
        )
        let descriptor = try TmuxProvider().makeAttachmentDescriptor(to: workspace, in: context)
        let attachment = try await TmuxProvider().openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 100, rows: 30),
            in: context
        )

        guard case let .byteTerminal(channel) = attachment.presentation else {
            Issue.record("tmux 首期 attachment 必须提供 byte terminal")
            return
        }
        #expect(attachment is any PersistentTerminalInteractiveAttachment)
        try await channel.write(Data("echo ok\n".utf8))
        try await channel.resize(.init(cols: 120, rows: 40))
        await attachment.close()
        await attachment.close()

        let request = try #require(await recorder.value)
        #expect(request.command.contains("attach-session"))
        #expect(request.command.contains("$1"))
        #expect(request.terminal?.size == .init(cols: 100, rows: 30))

        #expect(
            request.command.contains(
                "\"$$\"\nexec /opt/bin/tmux attach-session"
            )
        )
    }

    @Test("tmux 握手帧用真实换行结束 printf 后再执行目标进程")
    func handshakeWrappersSeparatePrintfFromExec() {
        let attach = tmuxHandshakeScript(
            kind: .attachment,
            nonce: "ATTACH_NONCE",
            invocation: "exec /opt/bin/tmux attach-session -t '$1'"
        )
        let control = tmuxHandshakeScript(
            kind: .control,
            nonce: "CONTROL_NONCE",
            invocation: "exec /opt/bin/tmux -CC attach-session -t '$1'"
        )

        #expect(
            attach
                == "printf '__CONN_TMUX_ATTACH_v1__ nonce=ATTACH_NONCE tty=%s pid=%s\\n' \"$(tty)\" \"$$\"\nexec /opt/bin/tmux attach-session -t '$1'"
        )
        #expect(
            control
                == "printf '__CONN_TMUX_CONTROL_v1__ nonce=CONTROL_NONCE tty=%s pid=%s\\n' \"$(tty)\" \"$$\"\nexec /opt/bin/tmux -CC attach-session -t '$1'"
        )
    }

    @Test("同一远端 Session 的两个本地 attachment 使用不同的运行时身份")
    func attachmentsToSameSessionHaveDistinctRuntimeIdentities() async throws {
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            let marker = request.command.contains("-CC")
                ? "__CONN_TMUX_CONTROL_v1__"
                : "__CONN_TMUX_ATTACH_v1__"
            let nonce = request.command
                .components(separatedBy: "nonce=")
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            let tty = request.command.contains("-CC") ? "/dev/pts/2" : "/dev/pts/1"
            let pid = request.command.contains("-CC") ? 200 : 100
            let suffix = request.command.contains("-CC") ? "\u{1B}P1000p\u{1B}" : ""
            return RecordingProcessChannel(outputs: [
                .stdout(Data("\(marker) nonce=\(nonce) tty=\(tty) pid=\(pid)\n\(suffix)".utf8)),
            ])
        }
        let context = try await makeContext(behavior: behavior(processFactory: processFactory))
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux-1000/default",
            serverPID: 1234,
            serverStartTime: 987654
        )
        let descriptor = try TmuxProvider().makeAttachmentDescriptor(
            to: RemoteWorkspaceRef(
                workspaceID: "$1",
                instancePayloadVersion: 1,
                providerInstancePayload: try JSONEncoder().encode(
                    TmuxWorkspaceInstancePayload(serverInstanceToken: token)
                )
            ),
            in: context
        )

        let first = try await TmuxProvider().openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 100, rows: 30),
            in: context
        )
        let second = try await TmuxProvider().openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 100, rows: 30),
            in: context
        )
        let firstIdentity = try #require(
            (first as? any TmuxRuntimeAttachmentIdentifying)?.runtimeAttachmentID
        )
        let secondIdentity = try #require(
            (second as? any TmuxRuntimeAttachmentIdentifying)?.runtimeAttachmentID
        )
        await first.close()
        await second.close()
        #expect(firstIdentity != secondIdentity)
        #expect(firstIdentity != descriptor.workspace.workspaceID)
        #expect(secondIdentity != descriptor.workspace.workspaceID)
    }

    @Test("数据握手超时降级时按原序保留未识别 preamble")
    func preservesPreambleWhenDataHandshakeDegrades() async throws {
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            if request.command.contains("-CC") {
                let nonce = request.command
                    .components(separatedBy: "nonce=")
                    .last?
                    .split(whereSeparator: { $0 == " " || $0 == "'" })
                    .first
                    .map(String.init) ?? "test"
                return RecordingProcessChannel(
                    outputs: [.stdout(Data(
                        "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p\u{1B}".utf8
                    ))]
                )
            }
            return HoldingProcessChannel(
                initialOutput: .stdout(Data("remote banner\npartial".utf8))
            )
        }
        let context = try await makeContext(behavior: behavior(processFactory: processFactory))
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux-1000/default",
            serverPID: 1234,
            serverStartTime: 987654
        )
        let workspace = RemoteWorkspaceRef(
            workspaceID: "$1",
            instancePayloadVersion: 1,
            providerInstancePayload: try JSONEncoder().encode(
                TmuxWorkspaceInstancePayload(serverInstanceToken: token)
            )
        )
        let descriptor = try TmuxProvider().makeAttachmentDescriptor(to: workspace, in: context)
        let attachment = try await TmuxProvider().openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 100, rows: 30),
            in: context
        )
        guard case let .byteTerminal(channel) = attachment.presentation else {
            Issue.record("tmux 首期 attachment 必须提供 byte terminal")
            return
        }
        var iterator = channel.output.makeAsyncIterator()
        #expect(try await iterator.next() == Data("remote banner\npartial".utf8))
        await attachment.close()
    }

    @Test("空 server 的 Catalog 返回可用的空快照而不创建远端 Session")
    func emptyCatalogReturnsSnapshotWithoutBootstrap() async throws {
        let context = try await makeContext(
            behavior: behavior(serverRunning: true, sessionID: "", sessionName: "")
        )
        let catalog = try await TmuxProvider().openCatalog(in: context)
        var iterator = catalog.snapshots.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())
        #expect(snapshot.workspaces.isEmpty)
        #expect(snapshot.freshness == PersistentWorkspaceCatalogFreshness.snapshot(observedAt: snapshot.observedAt))
        await catalog.close()
    }

    @Test("server 尚未启动时 Catalog 仍返回可创建首个 Session 的空状态")
    func absentServerCatalogReturnsCreateCapableEmptySnapshot() async throws {
        let context = try await makeContext(behavior: behavior(serverRunning: false))

        let catalog = try await TmuxProvider().openCatalog(in: context)
        var iterator = catalog.snapshots.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())

        #expect(snapshot.providerID == TmuxProvider.providerID)
        #expect(snapshot.profileID == context.backendProfile.id)
        #expect(snapshot.instance == nil)
        #expect(snapshot.workspaces.isEmpty)
        #expect(snapshot.freshness == .snapshot(observedAt: snapshot.observedAt))
        await catalog.close()
    }

    @Test("Control Mode 不可用时 Catalog 降级为可用快照")
    func catalogFallsBackToSnapshotWhenControlModeIsUnavailable() async throws {
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            if request.command.contains("-CC") {
                return RecordingProcessChannel(outputs: [])
            }
            let nonce = request.command
                .components(separatedBy: "nonce=")
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            return RecordingProcessChannel(outputs: [
                .stdout(Data(
                    "__CONN_TMUX_ATTACH_v1__ nonce=\(nonce) tty=/dev/pts/1 pid=100\n".utf8
                )),
            ])
        }
        let context = try await makeContext(
            behavior: behavior(processFactory: processFactory)
        )

        let catalog = try await TmuxProvider().openCatalog(in: context)
        var iterator = catalog.snapshots.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())
        #expect(snapshot.workspaces.map(\.name) == ["main"])
        #expect(snapshot.freshness == .snapshot(observedAt: snapshot.observedAt))
        await catalog.close()
    }

    @Test("数据 Attach 后重新校验 server identity，避免接入新 server")
    func attachmentRejectsServerRestartBetweenProbeAndAttach() async throws {
        let identitySequence = ServerIdentitySequence(values: [
            "/tmp/tmux-1000/default\n1234\n987654\n",
            "/tmp/tmux-1000/default\n2345\n999999\n",
        ])
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            if request.command.contains("-CC") {
                return RecordingProcessChannel(outputs: [])
            }
            let nonce = request.command
                .components(separatedBy: "nonce=")
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            return RecordingProcessChannel(outputs: [
                .stdout(Data(
                    "__CONN_TMUX_ATTACH_v1__ nonce=\(nonce) tty=/dev/pts/1 pid=100\n".utf8
                )),
            ])
        }
        var configured = behavior(processFactory: processFactory)
        let fallbackResponder = configured.dynamicResponder
        configured.dynamicResponder = { command, endpoint in
            if command.contains("socket_path") {
                return .init(stdout: identitySequence.next())
            }
            return fallbackResponder?(command, endpoint)
        }
        let context = try await makeContext(behavior: configured)
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux-1000/default",
            serverPID: 1234,
            serverStartTime: 987654
        )
        let workspace = RemoteWorkspaceRef(
            workspaceID: "$1",
            instancePayloadVersion: 1,
            providerInstancePayload: try JSONEncoder().encode(
                TmuxWorkspaceInstancePayload(serverInstanceToken: token)
            )
        )
        let descriptor = try TmuxProvider().makeAttachmentDescriptor(to: workspace, in: context)

        await #expect(throws: PersistentTerminalError.serverInstanceChanged) {
            _ = try await TmuxProvider().openAttachment(
                descriptor,
                reason: .initial,
                terminalSize: .init(cols: 100, rows: 30),
                in: context
            )
        }
    }
}

private func makeProfile(configurationKey: String = "default") -> TerminalBackendProfile {
    let configuration = TmuxProviderConfiguration(locator: .default)
    let data = try! JSONEncoder().encode(configuration)
    return TerminalBackendProfile(
        id: "profile-1",
        hostID: "host-1",
        providerID: TmuxProvider.providerID,
        providerConfigurationKey: configurationKey,
        displayName: "tmux",
        configurationJSON: String(decoding: data, as: UTF8.self)
    )
}

private func makeContext(
    behavior: MockSSHTransport.Behavior,
    profile: TerminalBackendProfile = makeProfile()
) async throws -> PersistentTerminalContext {
    let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
    let manager = ConnectionManager(
        transport: MockSSHTransport(behavior: behavior),
        platformDetector: FixedPlatformDetector(kind: .linux)
    )
    let remote = try await manager.platformContext(for: host)
    return try PersistentTerminalContext(platformContext: remote, backendProfile: profile)
}

private func behavior(
    tmuxInstalled: Bool = true,
    serverRunning: Bool = true,
    sessionID: String = "$1",
    sessionName: String = "main",
    processFactory: MockSSHTransport.ProcessFactory? = nil
) -> MockSSHTransport.Behavior {
    var behavior = MockSSHTransport.Behavior(
        processResponses: [:],
        processFactory: processFactory
    )
    behavior.commandResponses["command -v sh"] = .init(stdout: "/bin/sh\n")
    behavior.dynamicResponder = { command, _ in
        if command.contains("set -eu"), !serverRunning {
            return .init(stdout: "\(sessionID)\n/tmp/tmux-1000/default\n1234\n987654\n")
        }
        if command.contains("command -v tmux") {
            return tmuxInstalled
                ? .init(stdout: "/opt/bin/tmux\n")
                : .init(stderr: "tmux: command not found", exitCode: 127)
        }
        if command.contains("socket_path") {
            return serverRunning
                ? .init(stdout: "/tmp/tmux-1000/default\n1234\n987654\n")
                : .init(stderr: "no server running", exitCode: 1)
        }
        if command.contains("list-sessions") {
            return .init(stdout: "\(sessionID)\n")
        }
        if command.contains("session_name") {
            return .init(stdout: "\(sessionName)\n")
        }
        if command.contains("list-commands") {
            return .init(stdout: "attach-session\nlist-sessions\n")
        }
        if command.contains(" -V") {
            return .init(stdout: "tmux 3.4\n")
        }
        if command.contains("new-session") {
            return .init(stdout: "\(sessionID)\n")
        }
        return nil
    }
    return behavior
}

private struct FixedPlatformDetector: RemotePlatformDetecting {
    let kind: RemotePlatformKind

    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        RemotePlatformProfile(kind: kind, shell: .sh)
    }
}

private actor ProcessRequestRecorder {
    private(set) var value: RemoteProcessRequest?

    func record(_ request: RemoteProcessRequest) {
        value = request
    }
}

private final class RecordingProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>

    init(outputs: [RemoteProcessOutput] = []) {
        output = AsyncThrowingStream { continuation in
            for output in outputs { continuation.yield(output) }
            continuation.finish()
        }
    }

    func write(_ data: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func result() async throws -> RemoteProcessExit { .init(exitCode: 0, signal: nil) }
    func close() async {}
}

private final class HoldingProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>
    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let lock = NSLock()
    private var didClose = false

    init(initialOutput: RemoteProcessOutput) {
        (output, continuation) = AsyncThrowingStream.makeStream()
        continuation.yield(initialOutput)
    }

    func write(_ data: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func result() async throws -> RemoteProcessExit { .init(exitCode: nil, signal: nil) }

    func close() async {
        guard lock.withLock({
            guard !didClose else { return false }
            didClose = true
            return true
        }) else { return }
        continuation.finish()
    }
}

private final class ServerIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.withLock {
            values.isEmpty ? "/tmp/tmux-1000/default\n2345\n999999\n" : values.removeFirst()
        }
    }
}
