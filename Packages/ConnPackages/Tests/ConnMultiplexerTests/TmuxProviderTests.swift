import ConnKit
import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("Tmux provider")
struct TmuxProviderTests {
    @Test("带字母后缀的现代 tmux 版本使用 quoted snapshot codec")
    func modernReleaseSuffixUsesQuotedSnapshotCodec() {
        #expect(
            tmuxProtocolDialectCandidate(for: "tmux 3.5a").snapshotCodec == .quoted
        )
        #expect(
            tmuxProtocolDialectCandidate(for: "next-3.6a").commandGuardShape == .threeFields
        )
        #expect(
            tmuxProtocolDialectCandidate(for: "2.6").snapshotCodec == .legacyPerField
        )
    }

    @Test("Control Mode provider fixture exposes both required clients")
    func controlFixtureExposesRequiredClients() async throws {
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux-1000/default",
            serverPID: 1234,
            serverStartTime: 987654
        )
        let scope = try TmuxOperationScope(
            connectionIdentity: SSHConnectionIdentity(host: Host(
                id: "host-1",
                name: "Linux",
                address: "linux.local",
                username: "tester"
            )),
            configurationKey: "default",
            instanceToken: token,
            generation: 1
        )
        let channel = RecordingProcessChannel(outputs: [
            .stdout(TmuxProtocolMarker.start + Data("%begin 1 1 0\n%end 1 1 0\n".utf8)),
        ])
        let runtime = try TmuxControlRuntime(
            channel: channel,
            scope: scope,
            dialect: .init(commandGuardShape: .threeFields, snapshotCodec: .quoted),
            processIdentity: .init(tty: "/dev/pts/2", processID: 200)
        )
        try await runtime.start(timeout: .seconds(1))
        let snapshot = try await runtime.loadSnapshot(
            reason: .userRequested,
            identities: [],
            controlClientID: nil,
            timeout: .seconds(1)
        )

        #expect(snapshot.instance.token == token)
        #expect(snapshot.clients.values.contains {
            $0.tty == "/dev/pts/2" && $0.id.processID == 200 && $0.kind == .controlMode
        })
        #expect(snapshot.clients.values.contains {
            $0.tty == "/dev/pts/1" && $0.id.processID == 100 && $0.kind == .interactiveTerminal
        })
        let controlClient = try #require(snapshot.clients.values.first {
            $0.tty == "/dev/pts/2" && $0.id.processID == 200
        })
        let dataClient = try #require(snapshot.clients.values.first {
            $0.tty == "/dev/pts/1" && $0.id.processID == 100
        })
        let identity = TmuxControlInteractiveIdentity(
            attachmentID: "attachment",
            clientID: dataClient.id,
            requestedSessionID: try #require(TmuxSessionID(rawValue: "$1"))
        )
        let owned = try await runtime.loadSnapshot(
            reason: .userRequested,
            identities: [identity],
            controlClientID: controlClient.id,
            timeout: .seconds(1)
        )
        #expect(owned.clients[dataClient.id]?.role == .connInteractive(
            attachmentID: "attachment"
        ))
        await runtime.close()
    }

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
        let context = try await makeContext(
            behavior: behavior(serverRunning: false, sessionName: "first")
        )
        let summary = try await TmuxProvider().createWorkspace(
            CreateWorkspaceRequest(name: "first"),
            in: context
        )
        let workspace = summary.workspace
        #expect(summary.name == "first")
        #expect(workspace.workspaceID == "$1")
        let payload = try JSONDecoder().decode(
            TmuxWorkspaceInstancePayload.self,
            from: workspace.providerInstancePayload
        )
        #expect(payload.serverInstanceToken.serverPID == 1234)
    }

    @Test("已有 server 创建时使用 tmux 返回的自动 Session 名称")
    func createReturnsTmuxGeneratedSessionName() async throws {
        let context = try await makeContext(
            behavior: behavior(sessionID: "$8", sessionName: "generated")
        )

        let summary = try await TmuxProvider().createWorkspace(.init(), in: context)

        #expect(summary.workspace.workspaceID == "$8")
        #expect(summary.name == "generated")
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
        let configuration = makeConfiguration()
        let host = Host(id: "host-1", name: "Windows", address: "win.local", username: "tester")
        // The platform context itself needs a live session. A normal mock is used here;
        // the provider must return before it can issue any command.
        let remote = try await ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector(kind: .windows)
        ).platformContext(for: host)
        let context = PersistentTerminalContext(
            platformContext: remote,
            backendConfiguration: configuration
        )
        let availability = try await TmuxProvider().probe(in: context)

        #expect(availability.state == .unsupported)
        #expect(availability.issue == .unsupportedPlatform)
    }

    @Test("配置 key 与 locator 不一致时拒绝 configuration")
    func configurationLocatorMismatchIsRejected() async throws {
        let context = try await makeContext(
            behavior: behavior(),
            configuration: makeConfiguration(configurationKey: "named:wrong")
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

    @Test("同一启动连接复用静态 probe 且每次目录刷新只有一个 tmux 往返")
    func workspaceDiscoveryReusesStaticProbeAndBatchesCatalog() async throws {
        let recorder = SynchronousCommandRecorder()
        let context = try await makeContext(behavior: behavior(commandRecorder: recorder))
        let provider = TmuxProvider()

        _ = try await provider.listWorkspaces(in: context)
        _ = try await provider.listWorkspaces(in: context)

        let commands = recorder.values
        // The mock's exact `command -v sh` fixture is resolved before its dynamic
        // recorder. The remaining wire operations are one static probe plus two
        // deliberately requested catalog refreshes.
        #expect(commands.count == 3)
        #expect(commands.filter { $0.contains("__CONN_TMUX_EXECUTABLE__") }.count == 1)
        #expect(commands.filter { $0.contains("#{q:session_id}") }.count == 2)
        #expect(!commands.contains { $0.contains("display-message -p -t") })
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
                        "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8
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

    @Test("Control Mode 未就绪时不创建数据 PTY，也不发布 tmux attachment")
    func controlModeIsARequiredStartupStage() async throws {
        let recorder = ProcessRequestListRecorder()
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            await recorder.record(request)
            if request.command.contains("-CC") {
                return RecordingProcessChannel(outputs: [])
            }
            let nonce = request.command
                .components(separatedBy: "nonce=")
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            return RecordingProcessChannel(outputs: [.stdout(Data(
                "__CONN_TMUX_ATTACH_v1__ nonce=\(nonce) tty=/dev/pts/1 pid=100\n".utf8
            ))])
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

        do {
            _ = try await TmuxProvider().openAttachment(
                descriptor,
                reason: .initial,
                terminalSize: .init(cols: 100, rows: 30),
                in: context
            )
            Issue.record("Control Mode 未就绪时不得发布 tmux attachment")
        } catch let failure as TerminalStartupFailure {
            #expect(failure.stageID == .controlPlane)
        }
        let requests = await recorder.values
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.command.contains("-CC") })
    }

    @Test("Control Mode 首次瞬时失败时在创建数据 PTY 前重建一次")
    func transientControlModeFailureRetriesBeforeOpeningDataPTY() async throws {
        let recorder = ProcessRequestListRecorder()
        let controlAttempts = ProcessAttemptCounter()
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            await recorder.record(request)
            let nonce = request.command
                .components(separatedBy: "nonce=")
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            if request.command.contains("-CC") {
                guard await controlAttempts.next() > 1 else {
                    return RecordingProcessChannel(outputs: [])
                }
                return RecordingProcessChannel(outputs: [.stdout(Data(
                    "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8
                ))])
            }
            return RecordingProcessChannel(outputs: [.stdout(Data(
                "__CONN_TMUX_ATTACH_v1__ nonce=\(nonce) tty=/dev/pts/1 pid=100\n".utf8
            ))])
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

        let attachment = try await TmuxProvider().openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 100, rows: 30),
            in: context
        )

        let requests = await recorder.values
        #expect(requests.count == 3)
        #expect(requests[0].command.contains("-CC"))
        #expect(requests[1].command.contains("-CC"))
        #expect(!requests[2].command.contains("-CC"))
        await attachment.close()
    }

    @Test("Control Mode 启动失败且目录中无目标 Session 时返回远端对象已丢失")
    func missingAttachmentSessionIsClassifiedAfterControlFailure() async throws {
        let processFactory: MockSSHTransport.ProcessFactory = { _ in
            RecordingProcessChannel(outputs: [])
        }
        let context = try await makeContext(
            behavior: behavior(
                sessionID: "$2",
                sessionName: "other",
                processFactory: processFactory
            )
        )
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

        do {
            _ = try await TmuxProvider().openAttachment(
                descriptor,
                reason: .reconnect,
                terminalSize: .init(cols: 80, rows: 24),
                in: context
            )
            Issue.record("目录中无目标 Session 时不得发布 attachment")
        } catch let failure as TerminalStartupFailure {
            #expect(failure.stageID == .controlPlane)
            #expect(failure.underlyingError as? PersistentTerminalError == .remoteObjectMissing)
        }
    }

    @Test("数据 tmux client 延迟注册时身份绑定会等待而不是误报 Control Mode 不可用")
    func delayedDataClientRegistrationIsAwaited() async throws {
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            let nonce = request.command
                .components(separatedBy: "nonce=")
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            if request.command.contains("-CC") {
                return RecordingProcessChannel(
                    outputs: [.stdout(Data(
                        "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8
                    ))],
                    interactiveClientsVisibleAfterSnapshot: 2
                )
            }
            return RecordingProcessChannel(outputs: [.stdout(Data(
                "__CONN_TMUX_ATTACH_v1__ nonce=\(nonce) tty=/dev/pts/1 pid=100\n".utf8
            ))])
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

        let attachment = try await TmuxProvider().openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 100, rows: 30),
            in: context
        )
        await attachment.close()
    }

    @Test("共享 Control Mode 失效会广播给每个 attachment 并进入重建状态")
    func controlModeTransportFailureInvalidatesEveryAttachment() async throws {
        let controlChannelBox = ProcessChannelBox()
        let dataIdentities = ProcessIdentitySource(values: [
            .init(tty: "/dev/pts/1", pid: 100),
            .init(tty: "/dev/pts/3", pid: 300),
        ])
        let interactiveClients = [
            TestProcessIdentity(tty: "/dev/pts/1", pid: 100),
            TestProcessIdentity(tty: "/dev/pts/3", pid: 300),
        ]
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            let nonce = request.command
                .components(separatedBy: "nonce=")
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            if request.command.contains("-CC") {
                let channel = RecordingProcessChannel(outputs: [.stdout(Data(
                    "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8
                ))], interactiveClients: interactiveClients)
                await controlChannelBox.store(channel)
                return channel
            }
            let identity = await dataIdentities.next()
            return RecordingProcessChannel(outputs: [.stdout(Data(
                "__CONN_TMUX_ATTACH_v1__ nonce=\(nonce) tty=\(identity.tty) pid=\(identity.pid)\n".utf8
            ))])
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
        let firstLifecycle = first.lifecycleEvents
        let secondLifecycle = second.lifecycleEvents
        let firstEventTask = Task {
            var iterator = firstLifecycle.makeAsyncIterator()
            return await iterator.next()
        }
        let secondEventTask = Task {
            var iterator = secondLifecycle.makeAsyncIterator()
            return await iterator.next()
        }

        let controlChannel = try #require(await controlChannelBox.value)
        controlChannel.fail(TmuxProviderTestError.transportLost)

        guard case let .failed(firstFailure)? = await firstEventTask.value,
              case let .failed(secondFailure)? = await secondEventTask.value
        else {
            Issue.record("Control Mode 传输失效必须向全部 attachment 广播 failure")
            return
        }
        for failure in [firstFailure, secondFailure] {
            #expect(failure.componentID.rawValue == "tmux.control-mode")
            #expect(failure.issue == .transportClosed)
            #expect(failure.recovery == .rebuildAttachment)
        }
        await first.close()
        await second.close()
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
        let dataIdentities = ProcessIdentitySource(values: [
            .init(tty: "/dev/pts/1", pid: 100),
            .init(tty: "/dev/pts/3", pid: 300),
        ])
        let interactiveClients = [
            TestProcessIdentity(tty: "/dev/pts/1", pid: 100),
            TestProcessIdentity(tty: "/dev/pts/3", pid: 300),
        ]
        let processFactory: MockSSHTransport.ProcessFactory = { request in
            let nonce = request.command
                .components(separatedBy: "nonce=")
                .last?
                .split(whereSeparator: { $0 == " " || $0 == "'" })
                .first
                .map(String.init) ?? "test"
            if request.command.contains("-CC") {
                return RecordingProcessChannel(
                    outputs: [.stdout(Data(
                        "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8
                    ))],
                    interactiveClients: interactiveClients
                )
            }
            let identity = await dataIdentities.next()
            return RecordingProcessChannel(outputs: [
                .stdout(Data(
                    "__CONN_TMUX_ATTACH_v1__ nonce=\(nonce) tty=\(identity.tty) pid=\(identity.pid)\n".utf8
                )),
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

    @Test("数据终端无法完成身份握手时拒绝发布 attachment")
    func rejectsAttachmentWhenDataHandshakeFails() async throws {
        let dataProcess = HoldingProcessChannel(
            initialOutput: .stdout(Data("remote banner\npartial".utf8))
        )
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
                        "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8
                    ))]
                )
            }
            return dataProcess
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
        do {
            _ = try await TmuxProvider().openAttachment(
                descriptor,
                reason: .initial,
                terminalSize: .init(cols: 100, rows: 30),
                in: context
            )
            Issue.record("身份绑定失败的 tmux attachment 不得发布")
        } catch let failure as TerminalStartupFailure {
            #expect(failure.stageID == .byteTerminal)
            #expect(failure.underlyingError is TmuxProviderError)
        }
        #expect(dataProcess.closeCount == 1)
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
        #expect(snapshot.configurationKey == context.backendConfiguration.configurationKey)
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
                let nonce = request.command
                    .components(separatedBy: "nonce=")
                    .last?
                    .split(whereSeparator: { $0 == " " || $0 == "'" })
                    .first
                    .map(String.init) ?? "test"
                return RecordingProcessChannel(outputs: [.stdout(Data(
                    "__CONN_TMUX_CONTROL_v1__ nonce=\(nonce) tty=/dev/pts/2 pid=200\n\u{1B}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8
                ))])
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

        do {
            _ = try await TmuxProvider().openAttachment(
                descriptor,
                reason: .initial,
                terminalSize: .init(cols: 100, rows: 30),
                in: context
            )
            Issue.record("server identity 已变化时不得发布 attachment")
        } catch let failure as TerminalStartupFailure {
            #expect(failure.stageID.rawValue == "tmux.server-identity")
            #expect(failure.underlyingError as? PersistentTerminalError == .serverInstanceChanged)
        }
    }
}

private func makeConfiguration(
    configurationKey: String = "default"
) -> PersistentTerminalConfiguration {
    let configuration = TmuxProviderConfiguration(locator: .default)
    let data = try! JSONEncoder().encode(configuration)
    return PersistentTerminalConfiguration(
        providerID: TmuxProvider.providerID,
        configurationKey: configurationKey,
        payloadVersion: TmuxProvider.configurationVersion,
        providerPayload: data
    )
}

private func makeContext(
    behavior: MockSSHTransport.Behavior,
    configuration: PersistentTerminalConfiguration = makeConfiguration()
) async throws -> PersistentTerminalContext {
    // The production registry intentionally shares one Control Runtime for an exact host
    // scope. Each parallel test needs an independent connection identity.
    let host = Host(
        id: "host-\(UUID().uuidString)",
        name: "Linux",
        address: "linux.local",
        username: "tester"
    )
    let manager = ConnectionManager(
        transport: MockSSHTransport(behavior: behavior),
        platformDetector: FixedPlatformDetector(kind: .linux)
    )
    let remote = try await manager.platformContext(for: host)
    return PersistentTerminalContext(
        platformContext: remote,
        backendConfiguration: configuration
    )
}

private func behavior(
    tmuxInstalled: Bool = true,
    serverRunning: Bool = true,
    sessionID: String = "$1",
    sessionName: String = "main",
    processFactory: MockSSHTransport.ProcessFactory? = nil,
    commandRecorder: SynchronousCommandRecorder? = nil
) -> MockSSHTransport.Behavior {
    var behavior = MockSSHTransport.Behavior(
        processResponses: [:],
        processFactory: processFactory
    )
    behavior.commandResponses["command -v sh"] = .init(stdout: "/bin/sh\n")
    behavior.dynamicResponder = { command, _ in
        commandRecorder?.record(command)
        if command.contains("set -eu"), !serverRunning {
            return .init(
                stdout: "\(sessionID)\t\(sessionName)\n/tmp/tmux-1000/default\n1234\n987654\n"
            )
        }
        if command.contains("__CONN_TMUX_EXECUTABLE__") {
            return tmuxInstalled
                ? .init(
                    stdout: "__CONN_TMUX_EXECUTABLE__/opt/bin/tmux\n"
                        + "__CONN_TMUX_VERSION__tmux 3.4\n"
                )
                : .init(stderr: "tmux: command not found", exitCode: 127)
        }
        if command.contains("#{q:socket_path}"), command.contains("#{q:session_id}") {
            guard serverRunning else {
                return .init(stderr: "no server running", exitCode: 1)
            }
            var stdout = "\"I\" \"/tmp/tmux-1000/default\" \"1234\" \"987654\"\n"
            if !sessionID.isEmpty {
                stdout += "\"S\" \"\(sessionID)\" \"\(sessionName)\" \"\"\n"
            }
            return .init(stdout: stdout)
        }
        if command.contains("socket_path") {
            return serverRunning
                ? .init(stdout: "/tmp/tmux-1000/default\n1234\n987654\n")
                : .init(stderr: "no server running", exitCode: 1)
        }
        if command.contains("list-sessions") {
            return .init(stdout: "\(sessionID)\n")
        }
        if command.contains("new-session") {
            let markerPrefix = "__CONN_TMUX_GUARD_ACCEPTED_"
            guard let start = command.range(of: markerPrefix),
                  let end = command[start.upperBound...].range(of: "__")
            else {
                return .init(stdout: "\(sessionID)\t\(sessionName)\n")
            }
            let marker = markerPrefix + command[start.upperBound ..< end.lowerBound] + "__"
            return .init(stdout: "\(marker)\n\(sessionID)\t\(sessionName)\n")
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
        return nil
    }
    return behavior
}

private final class SynchronousCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ command: String) {
        lock.lock()
        storage.append(command)
        lock.unlock()
    }
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

private actor ProcessRequestListRecorder {
    private(set) var values: [RemoteProcessRequest] = []

    func record(_ request: RemoteProcessRequest) {
        values.append(request)
    }
}

private actor ProcessAttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private actor ProcessChannelBox {
    private(set) var value: RecordingProcessChannel?

    func store(_ channel: RecordingProcessChannel) {
        value = channel
    }
}

private enum TmuxProviderTestError: Error {
    case transportLost
}

private final class RecordingProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>
    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let isControlMode: Bool
    private let interactiveClients: [TestProcessIdentity]
    private let interactiveClientsVisibleAfterSnapshot: Int
    private let lock = NSLock()
    private var commandNumber: UInt64 = 0
    private var snapshotNumber = 0
    private var didClose = false

    init(
        outputs: [RemoteProcessOutput] = [],
        interactiveClients: [TestProcessIdentity] = [
            .init(tty: "/dev/pts/1", pid: 100),
        ],
        interactiveClientsVisibleAfterSnapshot: Int = 1
    ) {
        (output, continuation) = AsyncThrowingStream.makeStream()
        self.interactiveClients = interactiveClients
        self.interactiveClientsVisibleAfterSnapshot = interactiveClientsVisibleAfterSnapshot
        isControlMode = outputs.contains { output in
            guard case let .stdout(data) = output else { return false }
            return data.range(of: TmuxProtocolMarker.start) != nil
        }
        for output in outputs { continuation.yield(output) }
        if !isControlMode { continuation.finish() }
    }

    func write(_ data: Data) async throws {
        guard isControlMode else { return }
        let command = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard !command.isEmpty else {
            continuation.finish()
            return
        }
        let response = lock.withLock { () -> String in
            commandNumber &+= 1
            if command.contains("__CONN_TMUX_SNAPSHOT_") {
                snapshotNumber += 1
            }
            var lines = ["%begin 10 \(commandNumber) 0"]
            lines.append(contentsOf: snapshotLines(
                for: command,
                includesInteractiveClients: snapshotNumber
                    >= interactiveClientsVisibleAfterSnapshot
            ))
            lines.append("%end 10 \(commandNumber) 0")
            return lines.joined(separator: "\n") + "\n"
        }
        continuation.yield(.stdout(Data(response.utf8)))
    }
    func resize(_ size: TermSize) async throws {}
    func result() async throws -> RemoteProcessExit { .init(exitCode: 0, signal: nil) }

    func close() async {
        guard lock.withLock({
            guard !didClose else { return false }
            didClose = true
            return true
        }) else { return }
        continuation.finish()
    }

    func fail(_ error: any Error) {
        continuation.finish(throwing: error)
    }

    private func snapshotLines(
        for command: String,
        includesInteractiveClients: Bool
    ) -> [String] {
        let markers = command.components(separatedBy: "'").filter {
            $0.hasPrefix("__CONN_TMUX_SNAPSHOT_")
        }
        guard !markers.isEmpty else { return [] }
        var result: [String] = []
        for marker in markers {
            result.append(marker)
            guard marker.hasSuffix("_BEGIN__") else { continue }
            if marker.contains("_server-identity-before_")
                || marker.contains("_server-identity-after_")
            {
                result.append(#""/tmp/tmux-1000/default" "1234" "987654" "3.4""#)
            } else if marker.contains("_sessions_") {
                result.append(#""$1" "main" """#)
            } else if marker.contains("_window-links_") {
                result.append(#""$1" "@1" "0" "1""#)
            } else if marker.contains("_windows_") {
                result.append(#""@1" "main" "layout" "0""#)
            } else if marker.contains("_panes_") {
                result.append(
                    #""@1" "%1" "0" "shell" "sh" "/tmp" "100" "30" "0" "1" "0" "0" "" "0" "10" "2000""#
                )
            } else if marker.contains("_clients_") {
                result.append(
                    #""/dev/pts/2" "/dev/pts/2" "200" "2000" "$1" "@1" "%1" "no-output,wait-exit,ignore-size" "1""#
                )
                guard includesInteractiveClients else { continue }
                result.append(contentsOf: interactiveClients.map { client in
                    "\"\(client.tty)\" \"\(client.tty)\" \"\(client.pid)\" \"\(client.pid * 10)\" \"$1\" \"@1\" \"%1\" \"active-pane,ignore-size\" \"0\""
                })
            }
        }
        return result
    }
}

private final class HoldingProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>
    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let lock = NSLock()
    private var didClose = false
    private var _closeCount = 0

    var closeCount: Int { lock.withLock { _closeCount } }

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
            _closeCount += 1
            return true
        }) else { return }
        continuation.finish()
    }
}

private struct TestProcessIdentity: Sendable {
    let tty: String
    let pid: Int32
}

private actor ProcessIdentitySource {
    private var values: [TestProcessIdentity]

    init(values: [TestProcessIdentity]) {
        self.values = values
    }

    func next() -> TestProcessIdentity {
        if values.isEmpty {
            return .init(tty: "/dev/pts/99", pid: 9_900)
        }
        return values.removeFirst()
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
