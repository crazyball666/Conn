import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMultiplexer

@Suite("Zellij provider")
struct ZellijProviderTests {
    @Test("probe 只检测可执行文件，不读取或限制版本")
    func probeDoesNotGateByVersion() async throws {
        let recorder = ZellijCommandRecorder()
        let context = try await makeZellijContext(
            recorder: recorder,
            responder: { command in
                command == "command -v zellij"
                    ? .init(stdout: "/opt/bin/zellij\n")
                    : nil
            }
        )

        let availability = try await ZellijProvider().probe(in: context)

        #expect(availability.state == .available)
        #expect(availability.issue == nil)
        #expect(availability.effectiveFeatures == [
            .workspaceDiscovery,
            .workspaceCreation,
            .workspaceDestruction
        ])
        #expect(recorder.values.count == 1)
        #expect(recorder.values[0].contains("__CONN_EXECUTABLES_v1_BEGIN_"))
        #expect(recorder.values[0].contains("-i -l -c"))
        #expect(!recorder.values.contains { $0.contains("--version") || $0.contains(" -V") })
    }

    @Test("未安装 Zellij 时返回 unavailable，而不是版本不兼容")
    func probeReportsMissingExecutable() async throws {
        let context = try await makeZellijContext { command in
            command == "command -v zellij"
                ? .init(stderr: "zellij: not found", exitCode: 127)
                : nil
        }

        let availability = try await ZellijProvider().probe(in: context)

        #expect(availability.state == .unavailable)
        #expect(availability.issue == .executableMissing)
    }

    @Test("macOS 使用登录 Shell 环境而不猜测包管理器安装目录")
    func macOSProbeUsesGenericLoginShellEnvironment() async throws {
        let recorder = ZellijCommandRecorder()
        let context = try await makeZellijContext(
            platform: .macOS,
            recorder: recorder,
            responder: { command in
                command == "command -v zellij"
                    ? .init(stdout: "/opt/homebrew/bin/zellij\n")
                    : nil
            }
        )

        let availability = try await ZellijProvider().probe(in: context)

        #expect(availability.state == .available)
        #expect(availability.issue == nil)
        let command = try #require(recorder.values.first)
        #expect(command.contains("conn_login_shell=${SHELL:-}"))
        #expect(command.contains("-i -l -c"))
        #expect(!command.contains("/opt/homebrew/bin"))
        #expect(!command.contains("/usr/local/bin"))
        #expect(!command.contains("$HOME/.cargo/bin"))
        #expect(!command.contains("--version"))
    }

    @Test("Session 列表使用名称作为稳定 workspace identity")
    func listsSessionsByName() async throws {
        let context = try await makeZellijContext { command in
            if command == "command -v zellij" {
                return .init(stdout: "/opt/bin/zellij\n")
            }
            if command.contains("list-sessions --short --no-formatting") {
                return .init(stdout: "alpha\nteam ops\n")
            }
            return nil
        }

        let workspaces = try await ZellijProvider().listWorkspaces(in: context)

        #expect(workspaces.map(\.name) == ["alpha", "team ops"])
        #expect(workspaces.map(\.workspace.workspaceID) == ["alpha", "team ops"])
        #expect(workspaces.allSatisfy {
            $0.workspace.instancePayloadVersion == ZellijProvider.workspaceInstancePayloadVersion
        })
    }

    @Test("没有 Session 的标准诊断返回空列表")
    func noSessionsReturnsEmptyCatalog() async throws {
        let context = try await makeZellijContext { command in
            if command == "command -v zellij" {
                return .init(stdout: "/usr/bin/zellij\n")
            }
            if command.contains("list-sessions --short --no-formatting") {
                return .init(stderr: "No active zellij sessions found.", exitCode: 1)
            }
            return nil
        }

        #expect(try await ZellijProvider().listWorkspaces(in: context).isEmpty)
    }

    @Test("创建 Session 使用后台创建命令并安全引用名称")
    func createsBackgroundSession() async throws {
        let recorder = ZellijCommandRecorder()
        let context = try await makeZellijContext(
            recorder: recorder,
            responder: { command in
                if command == "command -v zellij" {
                    return .init(stdout: "/opt/bin/zellij\n")
                }
                if command.contains("attach --create-background") {
                    return .init()
                }
                return nil
            }
        )

        let workspace = try await ZellijProvider().createWorkspace(
            .init(name: "ops team's"),
            in: context
        )

        #expect(workspace.name == "ops team's")
        #expect(workspace.workspace.workspaceID == "ops team's")
        let createCommand = try #require(recorder.values.first {
            $0.contains("attach --create-background")
        })
        #expect(!createCommand.contains("attach --create-background --"))
        #expect(createCommand.contains("'ops team'\\''s'"))
    }

    @Test("省略名称时生成可恢复的 Conn Session 名称")
    func createsGeneratedSessionName() async throws {
        let context = try await makeZellijContext { command in
            if command == "command -v zellij" {
                return .init(stdout: "/opt/bin/zellij\n")
            }
            if command.contains("attach --create-background") {
                return .init()
            }
            return nil
        }

        let workspace = try await ZellijProvider().createWorkspace(.init(), in: context)

        #expect(workspace.name.hasPrefix("conn-"))
        #expect(workspace.name == workspace.workspace.workspaceID)
        #expect(!workspace.name.contains("/"))
    }

    @Test("控制字符和路径型 Session 名称被拒绝")
    func rejectsUnsafeSessionNames() async throws {
        let context = try await makeZellijContext { command in
            command == "command -v zellij"
                ? .init(stdout: "/opt/bin/zellij\n")
                : nil
        }
        let provider = ZellijProvider()

        for name in [".", "..", "-option", "a/b", "a\nb", "a\u{7F}b"] {
            await #expect(throws: PersistentTerminalError.invalidConfiguration) {
                try await provider.createWorkspace(.init(name: name), in: context)
            }
        }
    }

    @Test("Session 重命名不伪装成受支持能力")
    func renameIsExplicitlyUnsupported() async throws {
        let context = try await makeZellijContext { command in
            command == "command -v zellij"
                ? .init(stdout: "/opt/bin/zellij\n")
                : nil
        }
        let workspace = RemoteWorkspaceRef(
            workspaceID: "alpha",
            instancePayloadVersion: ZellijProvider.workspaceInstancePayloadVersion,
            providerInstancePayload: Data("{}".utf8)
        )

        await #expect(throws: PersistentTerminalError.unsupportedFeature(
            providerID: ZellijProvider.providerID,
            feature: "workspaceRename"
        )) {
            try await ZellijProvider().renameWorkspace(workspace, to: "beta", in: context)
        }
    }

    @Test("销毁 Session 使用 delete-session force")
    func destroysSessionAndResurrectionState() async throws {
        let recorder = ZellijCommandRecorder()
        let context = try await makeZellijContext(
            recorder: recorder,
            responder: { command in
                if command == "command -v zellij" {
                    return .init(stdout: "/opt/bin/zellij\n")
                }
                if command.contains("delete-session") {
                    return .init()
                }
                return nil
            }
        )
        let workspace = try await ZellijProvider().createWorkspace(
            .init(name: "temporary"),
            in: makeZellijContext { command in
                if command == "command -v zellij" {
                    return .init(stdout: "/opt/bin/zellij\n")
                }
                if command.contains("attach --create-background") {
                    return .init()
                }
                return nil
            }
        )

        try await ZellijProvider().destroyWorkspace(workspace.workspace, in: context)

        let destroyCommand = try #require(recorder.values.first { $0.contains("delete-session") })
        #expect(destroyCommand.contains("delete-session --force temporary"))
    }

    @Test("attachment 脚本先验证 Session，再握手并 exec attach")
    func attachmentScriptIsBoundToSessionName() throws {
        let name = try #require(ZellijSessionName(rawValue: "team ops"))

        let script = zellijAttachmentScript(
            executable: "/opt/bin/zellij",
            sessionName: name,
            nonce: "ABC123"
        )

        #expect(script.contains("list-sessions --short --no-formatting"))
        #expect(script.contains("if ! sessions=$("))
        #expect(!script.contains("|| true"))
        #expect(script.contains("__CONN_ZELLIJ_UNAVAILABLE_v1__ nonce=%s"))
        #expect(script.contains("grep -Fqx -- \"$session_name\""))
        #expect(script.contains("__CONN_ZELLIJ_MISSING_v1__ nonce=%s"))
        #expect(script.contains("__CONN_ZELLIJ_ATTACH_v1__ nonce=%s"))
        #expect(script.contains("exec \"$zellij_path\" attach \"$session_name\""))
        #expect(!script.contains("attach -- \"$session_name\""))
        #expect(script.contains("session_name='team ops'"))
    }

    @Test("PTY channel 移除私有握手并转发输出、输入和 resize")
    func processShellChannelForwardsTerminalTraffic() async throws {
        let process = ZellijTestProcessChannel(outputs: [
            .stdout(Data("__CONN_ZELLIJ_ATTACH_v1__ nonce=READY\r\nhello".utf8))
        ])
        let channel = try await ZellijProcessShellChannel.open(
            process: process,
            nonce: "READY"
        )

        var iterator = channel.output.makeAsyncIterator()
        #expect(try await iterator.next() == Data("hello".utf8))
        try await channel.write(Data("input".utf8))
        try await channel.resize(.init(cols: 120, rows: 40))
        await channel.close()
        await channel.close()

        #expect(process.writes == [Data("input".utf8)])
        #expect(process.sizes == [.init(cols: 120, rows: 40)])
        #expect(process.closeCount == 1)
    }

    @Test("并发终端输入通过同一 writer 串行写入")
    func shellChannelSerializesConcurrentWrites() async throws {
        let process = ZellijTestProcessChannel(
            outputs: [.stdout(Data("__CONN_ZELLIJ_ATTACH_v1__ nonce=SERIAL\n".utf8))],
            delayedWritePayload: Data("user".utf8)
        )
        let channel = try await ZellijProcessShellChannel.open(
            process: process,
            nonce: "SERIAL"
        )

        let userWrite = Task { try await channel.write(Data("user".utf8)) }
        while !process.events.contains("start:user") {
            try await Task.sleep(for: .milliseconds(1))
        }
        let macroWrite = Task { try await channel.write(Data([0x14, 0x6E])) }
        try await userWrite.value
        try await macroWrite.value

        #expect(process.events == [
            "start:user",
            "finish:user",
            "start:\u{14}n",
            "finish:\u{14}n"
        ])
        await channel.close()
    }

    @Test("关闭通道先终止底层进程以解除挂起写入")
    func closeInterruptsHangingWrite() async throws {
        let process = ZellijBlockingWriteProcessChannel()
        let channel = try await ZellijProcessShellChannel.open(
            process: process,
            nonce: "BLOCKING"
        )

        let writeTask = Task { try await channel.write(Data("blocked".utf8)) }
        while !process.didStartWrite {
            try await Task.sleep(for: .milliseconds(1))
        }
        let closeTask = Task { await channel.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.closeCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(process.closeCount == 1)
        await process.forceRelease()
        await closeTask.value
        _ = await writeTask.result
    }

    @Test("缺失 Session 握手直接分类为 remoteObjectMissing")
    func missingSessionHandshakeIsTyped() async {
        let process = ZellijTestProcessChannel(outputs: [
            .stdout(Data("__CONN_ZELLIJ_MISSING_v1__ nonce=MISSING\n".utf8))
        ])

        await #expect(throws: PersistentTerminalError.remoteObjectMissing) {
            try await ZellijProcessShellChannel.open(process: process, nonce: "MISSING")
        }
        #expect(process.closeCount == 1)
    }

    @Test("Session 查询失败不会误判为远端 Session 缺失")
    func failedSessionQueryIsServerUnavailable() async {
        let process = ZellijTestProcessChannel(outputs: [
            .stdout(Data("__CONN_ZELLIJ_UNAVAILABLE_v1__ nonce=FAILED\n".utf8))
        ])

        await #expect(throws: PersistentTerminalError.serverUnavailable) {
            try await ZellijProcessShellChannel.open(process: process, nonce: "FAILED")
        }
        #expect(process.closeCount == 1)
    }

    @Test("远端未返回握手标记时按时失败而不永久阻塞")
    func missingHandshakeMarkerTimesOut() async {
        let process = ZellijTestProcessChannel(outputs: [])

        await #expect(throws: PersistentTerminalError.protocolViolation) {
            try await ZellijProcessShellChannel.open(
                process: process,
                nonce: "TIMEOUT",
                readinessTimeout: .milliseconds(20)
            )
        }
        #expect(process.closeCount == 1)
    }

    @Test("provider attachment 使用带 PTY 的同一 descriptor 路由 initial 与 reconnect")
    func opensPTYAttachmentFromDescriptor() async throws {
        let requests = ZellijProcessRequestRecorder()
        let context = try await makeZellijContext(
            processFactory: { request in
                requests.record(request)
                let nonce = try #require(zellijNonce(in: request.command))
                return ZellijTestProcessChannel(outputs: [
                    .stdout(Data("__CONN_ZELLIJ_ATTACH_v1__ nonce=\(nonce)\nready".utf8))
                ])
            },
            responder: { command in
                command == "command -v zellij"
                    ? .init(stdout: "/opt/bin/zellij\n")
                    : nil
            }
        )
        let workspace = try RemoteWorkspaceRef(
            workspaceID: "alpha",
            instancePayloadVersion: ZellijProvider.workspaceInstancePayloadVersion,
            providerInstancePayload: JSONEncoder().encode(ZellijWorkspaceInstancePayload())
        )
        let provider = ZellijProvider()
        let descriptor = try provider.makeAttachmentDescriptor(to: workspace, in: context)

        let initial = try await provider.openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 90, rows: 30),
            in: context
        )
        await initial.close()
        let reconnect = try await provider.openAttachment(
            descriptor,
            reason: .reconnect,
            terminalSize: .init(cols: 110, rows: 36),
            in: context
        )

        #expect(initial.descriptor == descriptor)
        #expect(reconnect.descriptor == descriptor)
        #expect(initial.viewportAuthority == .localTranscript)
        #expect(reconnect.viewportAuthority == .localTranscript)
        #expect(requests.values.map(\.terminal?.size) == [
            .init(cols: 90, rows: 30),
            .init(cols: 110, rows: 36)
        ])
        #expect(requests.values.allSatisfy { $0.terminal?.type == "xterm-256color" })
        #expect(requests.values.allSatisfy { $0.command.contains("zellij_path=/opt/bin/zellij") })
        await reconnect.close()
    }

    @Test("Tab 切换通过指定 Session 的 CLI action 执行")
    func tabNavigationTargetsAttachedSessionThroughCLI() async throws {
        let commands = ZellijCommandRecorder()
        let context = try await makeZellijContext(
            recorder: commands,
            processFactory: { request in
                let nonce = try #require(zellijNonce(in: request.command))
                return ZellijTestProcessChannel(outputs: [
                    .stdout(Data(
                        "__CONN_ZELLIJ_ATTACH_v1__ nonce=\(nonce)\nready".utf8
                    ))
                ])
            },
            responder: { command in
                if command == "command -v zellij" {
                    return .init(stdout: "/opt/bin/zellij\n")
                }
                if command.contains(" action go-to-next-tab") {
                    return .init()
                }
                return nil
            }
        )
        let workspace = try RemoteWorkspaceRef(
            workspaceID: "team ops",
            instancePayloadVersion: ZellijProvider.workspaceInstancePayloadVersion,
            providerInstancePayload: JSONEncoder().encode(ZellijWorkspaceInstancePayload())
        )
        let provider = ZellijProvider()
        let descriptor = try provider.makeAttachmentDescriptor(to: workspace, in: context)
        let attachment = try await provider.openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 90, rows: 30),
            in: context
        )
        let interactive = try #require(
            attachment as? any PersistentTerminalInteractiveAttachment
        )
        let state = try await interactive.interaction.resolveState()

        _ = try await interactive.interaction.performQuickAction(.init(
            actionID: ZellijTerminalQuickAction.nextTab.rawValue,
            target: state.target,
            attachmentGeneration: state.attachmentGeneration,
            expectedStateRevision: state.revision
        ))

        #expect(commands.values.contains(
            "/opt/bin/zellij --session 'team ops' action go-to-next-tab"
        ))
        await attachment.close()
    }

    @Test("CLI executor 将 Pane、重命名与删除操作定向到当前 Session")
    func cliExecutorTargetsSessionWithoutTerminalInputMacros() async throws {
        let commands = ZellijCommandRecorder()
        let context = try await makeZellijContext(
            recorder: commands,
            responder: { command in
                command.contains("/opt/bin/zellij") ? .init() : nil
            }
        )
        let sessionName = try #require(ZellijSessionName(rawValue: "team ops"))
        let executor = ZellijCLIActionExecutor(
            executable: "/opt/bin/zellij",
            sessionName: sessionName,
            session: context.session
        )

        try await executor.execute(arguments: ["focus-next-pane"], repeatCount: 1)
        try await executor.execute(arguments: ["rename-pane", "editor pane"], repeatCount: 1)
        try await executor.deleteSession()

        #expect(commands.values.suffix(3) == [
            "/opt/bin/zellij --session 'team ops' action focus-next-pane",
            "/opt/bin/zellij --session 'team ops' action rename-pane 'editor pane'",
            "/opt/bin/zellij delete-session 'team ops' --force"
        ])
    }
}

private func makeZellijContext(
    platform: RemotePlatformKind = .linux,
    recorder: ZellijCommandRecorder? = nil,
    processFactory: MockSSHTransport.ProcessFactory? = nil,
    responder: @escaping @Sendable (String) -> MockSSHTransport.CommandResponse?
) async throws -> PersistentTerminalContext {
    var behavior = MockSSHTransport.Behavior(
        processResponses: [:],
        processFactory: processFactory
    )
    behavior.dynamicResponder = { command, _ in
        recorder?.record(command)
        if let response = zellijExecutableResolutionResponse(
            for: command,
            legacyResponse: responder("command -v zellij")
        ) {
            return response
        }
        return responder(command)
    }
    let host = Host(
        id: "zellij-\(UUID().uuidString)",
        name: "Linux",
        address: "linux.example",
        username: "tester"
    )
    let manager = ConnectionManager(
        transport: MockSSHTransport(behavior: behavior),
        platformDetector: ZellijFixedPlatformDetector(kind: platform)
    )
    let remote = try await manager.platformContext(for: host)
    return PersistentTerminalContext(
        platformContext: remote,
        backendConfiguration: ZellijProvider().defaultConfiguration
    )
}

private func zellijExecutableResolutionResponse(
    for command: String,
    legacyResponse: MockSSHTransport.CommandResponse?
) -> MockSSHTransport.CommandResponse? {
    guard let nonce = executableResolverNonce(in: command) else { return nil }
    let executable = legacyResponse?.exitCode == 0
        ? legacyResponse?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        : nil
    let directory = executable.flatMap { value -> String? in
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).deletingLastPathComponent().path
    } ?? "/fixture/bin"
    return .init(stdout: executableResolverOutput(
        nonce: nonce,
        path: "\(directory):/usr/bin:/bin",
        executables: ["/bin/sh", executable]
    ))
}

private func executableResolverNonce(in command: String) -> String? {
    let marker = "__CONN_EXECUTABLES_v1_BEGIN_"
    guard let range = command.range(of: marker) else { return nil }
    let suffix = command[range.upperBound...]
    guard let end = suffix.range(of: "__") else { return nil }
    let nonce = String(suffix[..<end.lowerBound])
    return nonce.isEmpty ? nil : nonce
}

private func executableResolverOutput(
    nonce: String,
    path: String,
    executables: [String?]
) -> String {
    var lines = ["__CONN_EXECUTABLES_v1_BEGIN_\(nonce)__", path]
    for (index, executable) in executables.enumerated() {
        lines.append("__CONN_EXECUTABLES_v1_ITEM_\(index)_\(nonce)__")
        lines.append(executable ?? "")
    }
    lines.append("__CONN_EXECUTABLES_v1_END_\(nonce)__")
    return lines.joined(separator: "\n")
}

private func zellijNonce(in command: String) -> String? {
    guard let range = command.range(of: "nonce=") else { return nil }
    let suffix = command[range.upperBound...]
    let value = suffix.prefix { $0.isLetter || $0.isNumber }
    return value.isEmpty ? nil : String(value)
}

private final class ZellijCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    var values: [String] {
        lock.withLock { commands }
    }

    func record(_ command: String) {
        lock.withLock { commands.append(command) }
    }
}

private struct ZellijFixedPlatformDetector: RemotePlatformDetecting {
    let kind: RemotePlatformKind

    func detect(on _: any SSHSession) async throws -> RemotePlatformProfile {
        RemotePlatformProfile(kind: kind, shell: .sh)
    }
}

private final class ZellijProcessRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RemoteProcessRequest] = []

    var values: [RemoteProcessRequest] {
        lock.withLock { requests }
    }

    func record(_ request: RemoteProcessRequest) {
        lock.withLock { requests.append(request) }
    }
}

private final class ZellijTestProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>

    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let lock = NSLock()
    private var storedWrites: [Data] = []
    private var storedSizes: [TermSize] = []
    private var storedCloseCount = 0
    private var storedEvents: [String] = []
    private let delayedWritePayload: Data?

    var writes: [Data] {
        lock.withLock { storedWrites }
    }

    var sizes: [TermSize] {
        lock.withLock { storedSizes }
    }

    var closeCount: Int {
        lock.withLock { storedCloseCount }
    }

    var events: [String] {
        lock.withLock { storedEvents }
    }

    init(outputs: [RemoteProcessOutput], delayedWritePayload: Data? = nil) {
        (output, continuation) = AsyncThrowingStream.makeStream()
        self.delayedWritePayload = delayedWritePayload
        for event in outputs {
            continuation.yield(event)
        }
    }

    func write(_ data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            storedWrites.append(data)
            storedEvents.append("start:\(text)")
        }
        if data == delayedWritePayload {
            try await Task.sleep(for: .milliseconds(40))
        }
        lock.withLock { storedEvents.append("finish:\(text)") }
    }

    func resize(_ size: TermSize) async throws {
        lock.withLock { storedSizes.append(size) }
    }

    func result() async throws -> RemoteProcessExit {
        .init(exitCode: 0, signal: nil)
    }

    func close() async {
        let shouldFinish = lock.withLock { () -> Bool in
            guard storedCloseCount == 0 else { return false }
            storedCloseCount = 1
            return true
        }
        if shouldFinish {
            continuation.finish()
        }
    }
}

private final class ZellijBlockingWriteProcessChannel:
    RemoteProcessChannel,
    @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>

    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let writeGate = ZellijBlockingWriteGate()
    private let lock = NSLock()
    private var storedDidStartWrite = false
    private var storedCloseCount = 0

    var didStartWrite: Bool {
        lock.withLock { storedDidStartWrite }
    }

    var closeCount: Int {
        lock.withLock { storedCloseCount }
    }

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
        continuation.yield(.stdout(Data(
            "__CONN_ZELLIJ_ATTACH_v1__ nonce=BLOCKING\n".utf8
        )))
    }

    func write(_ data: Data) async throws {
        _ = data
        lock.withLock { storedDidStartWrite = true }
        await writeGate.wait()
        throw PersistentTerminalError.transportClosed
    }

    func resize(_ size: TermSize) async throws {
        _ = size
    }

    func result() async throws -> RemoteProcessExit {
        .init(exitCode: nil, signal: "CLOSED")
    }

    func close() async {
        let shouldClose = lock.withLock { () -> Bool in
            guard storedCloseCount == 0 else { return false }
            storedCloseCount = 1
            return true
        }
        guard shouldClose else { return }
        await writeGate.release()
        continuation.finish()
    }

    func forceRelease() async {
        await writeGate.release()
    }
}

private actor ZellijBlockingWriteGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
