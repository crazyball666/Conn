import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Testing
@testable import Conn

@MainActor
struct DockerOperationsModelTests {
    @Test("旧的容器与镜像入口共用同一写操作闸门")
    func legacyContainerAndImageActionsShareOneGate() async {
        let gate = OperationGate()
        let session = GatedOperationSession(gate: gate)
        let history = RecordingHistory()
        let context = makeContext(session: { session })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let containers = DockerContainersModel(context: context, operations: operations)
        let images = DockerImagesModel(context: context, operations: operations)
        let container = ContainerInfo(
            id: "c1", name: "web", image: "nginx", state: .running, status: "Up", ports: ""
        )

        let first = Task { await containers.perform(.stop, on: container) }
        await gate.waitForFirstCommand()
        let second = Task { await images.prune() }
        await Task.yield()

        let blockedCommandCount = await gate.commandCount
        #expect(blockedCommandCount == 1)
        #expect(operations.activeOperation != nil)

        await gate.allow()
        await first.value
        await second.value

        let finalCommandCount = await gate.commandCount
        #expect(finalCommandCount == 1)
        #expect(operations.activeOperation == nil)
    }

    @Test("已知非零退出码也审计并只刷新受影响的镜像")
    func knownNonzeroAuditsAndRefreshesTargetScope() async {
        let session = OperationSession(result: ExecResult(
            exitCode: 1, stdout: Data("private-token".utf8), stderr: Data("denied".utf8)
        ))
        let history = RecordingHistory()
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let image = ImageInfo(imageID: "i1", repository: "registry/app", tag: "1", size: "1MB", created: "now")

        operations.requestDestructiveAction(.removeImage(image))
        let confirmed = await operations.confirmPendingAction(confirmation: image.displayName)

        #expect(confirmed)
        #expect(refreshes == [.images])
        let entry = history.entries.first
        #expect(entry?.state == .known)
        #expect(entry?.exitCode == 1)
        #expect(entry?.outputHead == nil)
        #expect(entry?.command.contains("private-token") == false)
    }

    @Test("没有最终结果的写操作记录未知且不自动刷新")
    func unknownWriteAuditsWithoutRefresh() async {
        let session = OperationSession(throwsUnknown: true)
        let history = RecordingHistory()
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let image = ImageInfo(imageID: "i1", repository: "app", tag: "1", size: "1MB", created: "now")

        operations.requestDestructiveAction(.removeImage(image))
        let confirmed = await operations.confirmPendingAction(confirmation: image.displayName)

        #expect(confirmed)
        #expect(refreshes.isEmpty)
        let entry = history.entries.first
        #expect(entry?.state == .unknown)
        #expect(entry?.exitCode == nil)
    }

    @Test("本地草稿校验失败不会写审计或启动远端命令")
    func invalidRunDoesNotAuditOrStartRemoteCommand() async {
        let session = OperationSession()
        let history = RecordingHistory()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: history
        )

        await operations.runContainer(DockerRunDraft(image: ""))

        #expect(history.entries.isEmpty)
        #expect(!session.didExecute)
    }

    @Test("审计摘要不保留命令、环境变量或远端输出")
    func auditSummaryRedactsSecretsAndRawOutput() async {
        let session = OperationSession(result: ExecResult(
            exitCode: 0, stdout: Data("remote stdout: token=from-server".utf8), stderr: Data()
        ))
        let history = RecordingHistory()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: history
        )
        let draft = DockerRunDraft(
            image: "nginx:latest", environment: [EnvironmentEntry(key: "API_TOKEN", value: "local-secret")]
        )

        await operations.runContainer(draft)

        let entry = history.entries.first
        #expect(entry?.command.contains("API_TOKEN") == false)
        #expect(entry?.command.contains("local-secret") == false)
        #expect(entry?.command.contains("from-server") == false)
        #expect(entry?.command.contains("docker run") == false)
        #expect(entry?.outputHead == nil)
    }

    @Test("破坏性待确认动作要求精确确认词")
    func destructivePendingActionRequiresConfirmationWord() {
        let container = ContainerInfo(
            id: "c1", name: "web", image: "nginx", state: .running, status: "Up", ports: ""
        )
        let action = DockerPendingAction.removeContainer(container)

        #expect(action.confirmationWord == container.name)
        #expect(!action.accepts(confirmation: "DELETE"))
        #expect(action.accepts(confirmation: container.name))
        #expect(DockerPendingAction.pruneImages.confirmationWord == "PRUNE")
    }

    @Test("拉取逐块交付输出，以相同 UUID 写入已知非零结果")
    func pullDeliversChunksAndUpdatesPendingAudit() async {
        let session = PullSession(
            chunks: ["layer-a\n", "layer-b\n"],
            result: .success(ExecResult(exitCode: 1, stdout: Data(), stderr: Data("denied".utf8)))
        )
        let history = RecordingHistory()
        var chunks: [String] = []
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)

        await operations.pullImage(reference: "registry.example/app:1") { chunks.append($0) }

        #expect(chunks == ["layer-a\n", "layer-b\n"])
        #expect(history.entries.count == 1)
        #expect(history.recordedIDs == history.updatedIDs)
        #expect(history.entries.first?.state == .known)
        #expect(history.entries.first?.exitCode == 1)
        #expect(refreshes == [.images])
    }

    @Test("拉取没有最终结果时把同一 pending 审计更新为未知")
    func pullWithoutFinalResultBecomesUnknownWithoutRefresh() async {
        let session = PullSession(chunks: ["layer-a\n"], result: .failure(.channelClosed))
        let history = RecordingHistory()
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)

        await operations.pullImage(reference: "registry.example/app:1") { _ in }

        #expect(history.entries.count == 1)
        #expect(history.recordedIDs == history.updatedIDs)
        #expect(history.entries.first?.state == .unknown)
        #expect(history.entries.first?.exitCode == nil)
        #expect(refreshes.isEmpty)
    }

    @Test("pending 审计无法落盘时不启动远端拉取")
    func pullDoesNotStartWhenPendingAuditCannotPersist() async {
        let session = PullSession(chunks: [], result: .success(ExecResult(exitCode: 0, stdout: Data(), stderr: Data())))
        let history = RecordingHistory(failRecord: true)
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: history
        )

        await operations.pullImage(reference: "registry.example/app:1") { _ in }

        #expect(!session.didStart)
    }

    @Test("镜像删除拒绝错误确认，并只在资源名精确匹配时执行一次")
    func imageRemovalRequiresExactResourceConfirmation() async {
        let session = OperationSession()
        let history = RecordingHistory()
        let context = makeContext(session: { session })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let images = DockerImagesModel(context: context, operations: operations)
        let image = ImageInfo(imageID: "i1", repository: "registry/app", tag: "1", size: "1MB", created: "now")

        images.requestRemoval(image)
        let wrong = await operations.confirmPendingAction(confirmation: "registry/app")

        #expect(!wrong)
        #expect(session.executionCount == 0)
        #expect(operations.pendingDestructiveAction == .removeImage(image))

        let exact = await operations.confirmPendingAction(confirmation: image.displayName)

        #expect(exact)
        #expect(session.executionCount == 1)
        #expect(operations.pendingDestructiveAction == nil)
    }

    @Test("容器删除入口在空确认时不执行，并仅在名称精确匹配后执行")
    func containerRemovalStagesUntilExactResourceConfirmation() async {
        let session = OperationSession()
        let history = RecordingHistory()
        let context = makeContext(session: { session })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let containers = DockerContainersModel(context: context, operations: operations)
        let container = ContainerInfo(
            id: "c1", name: "api", image: "registry/app:1", state: .running, status: "Up", ports: ""
        )

        await containers.perform(.remove, on: container)

        #expect(operations.pendingDestructiveAction == .removeContainer(container))
        #expect(session.executionCount == 0)
        let empty = await operations.confirmPendingAction(confirmation: "")
        #expect(!empty)
        #expect(session.executionCount == 0)

        let exact = await operations.confirmPendingAction(confirmation: container.name)
        #expect(exact)
        #expect(session.executionCount == 1)
    }

    @Test("镜像清理只暂存，PRUNE 确认后才执行一次")
    func imagePruneStagesUntilPRUNEConfirmation() async {
        let session = OperationSession()
        let history = RecordingHistory()
        let context = makeContext(session: { session })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let images = DockerImagesModel(context: context, operations: operations)

        await images.prune()

        #expect(operations.pendingDestructiveAction == .pruneImages)
        #expect(session.executionCount == 0)
        let wrong = await operations.confirmPendingAction(confirmation: "prune")
        #expect(!wrong)
        #expect(session.executionCount == 0)

        let confirmed = await operations.confirmPendingAction(confirmation: "PRUNE")
        #expect(confirmed)
        #expect(session.executionCount == 1)
    }

    @Test("修改系统清理选项会替换待确认动作和确认词状态")
    func changingPruneOptionsReplacesPendingConfirmation() {
        let session = OperationSession()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: RecordingHistory()
        )
        let initial = DockerSystemPruneOptions()
        let changed = DockerSystemPruneOptions(allUnusedImages: true, includeVolumes: true)

        operations.requestDestructiveAction(.systemPrune(initial))
        let first = operations.pendingDestructiveAction
        operations.requestDestructiveAction(.systemPrune(changed))

        #expect(first == .systemPrune(initial))
        #expect(operations.pendingDestructiveAction == .systemPrune(changed))
        #expect(operations.pendingDestructiveAction?.confirmationWord == "PRUNE")
    }

    @Test("创建容器表单保留重复字段与 token 的输入顺序")
    func runFormStatePreservesDraftOrder() async {
        var state = DockerRunFormState()
        state.image = "registry.example/api:1"
        state.name = "api"
        state.detached = true
        state.network = "app-net"
        state.ports = [
            DockerPortRow(hostPort: "8080", containerPort: "80", protocol: .tcp),
            DockerPortRow(hostPort: "8443", containerPort: "443", protocol: .tcp)
        ]
        state.environment = [
            DockerEnvironmentRow(key: "FIRST", value: "one"),
            DockerEnvironmentRow(key: "SECOND", value: "two")
        ]
        state.mounts = [
            DockerMountRow(sourceKind: .namedVolume, source: "data", target: "/var/lib/api"),
            DockerMountRow(sourceKind: .bind, source: "/srv/config", target: "/etc/api", readOnly: true)
        ]
        state.otherOptions = [DockerTokenRow(value: "--cpus=1"), DockerTokenRow(value: "--add-host"), DockerTokenRow(value: "db:10.0.0.2")]
        state.command = [DockerTokenRow(value: "serve"), DockerTokenRow(value: "--foreground")]

        #expect(state.isValid)
        #expect(state.draft == DockerRunDraft(
            image: "registry.example/api:1", name: "api", detached: true, network: "app-net",
            ports: [
                PortBinding(hostPort: "8080", containerPort: "80"),
                PortBinding(hostPort: "8443", containerPort: "443")
            ],
            environment: [EnvironmentEntry(key: "FIRST", value: "one"), EnvironmentEntry(key: "SECOND", value: "two")],
            mounts: [
                MountEntry(source: .namedVolume("data"), target: "/var/lib/api"),
                MountEntry(source: .bind("/srv/config"), target: "/etc/api", readOnly: true)
            ],
            otherOptionTokens: ["--cpus=1", "--add-host", "db:10.0.0.2"],
            commandTokens: ["serve", "--foreground"]
        ))

        let session = OperationSession()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: RecordingHistory()
        )
        await operations.runContainer(state.draft)
        #expect(session.lastCommand == DockerCommand.run(state.draft, sudo: false))
    }

    @Test("非法创建草稿禁用继续，高风险配置会被显式标记")
    func runFormValidationAndRiskDetection() {
        var invalid = DockerRunFormState()
        #expect(!invalid.isValid)

        invalid.image = "nginx"
        invalid.ports = [DockerPortRow(hostPort: "0", containerPort: "80")]
        #expect(!invalid.isValid)

        var networkAlias = DockerRunFormState()
        networkAlias.image = "nginx"
        networkAlias.otherOptions = [DockerTokenRow(value: "--net=host")]
        #expect(!networkAlias.isValid)

        let risky = DockerRunDraft(
            image: "docker:dind", network: "host",
            mounts: [
                MountEntry(source: .bind("/var/run/docker.sock"), target: "/var/run/docker.sock"),
                MountEntry(source: .bind("/"), target: "/host")
            ],
            otherOptionTokens: ["--privileged"]
        )
        #expect(Set(DockerRunRiskDetector.detect(risky)) == [.privileged, .hostNetwork, .dockerSocket, .rootBind])
    }

    @Test("pull 仅受控关闭：活动拒绝、终态由完成动作关闭")
    func activePullCannotDismissUntilTerminalResult() async {
        let gate = OperationGate()
        let session = GatedPullSession(gate: gate)
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: RecordingHistory()
        )

        let pull = Task { await operations.pullImage(reference: "registry.example/app:1") { _ in } }
        await gate.waitForFirstCommand()

        #expect(operations.isPullActive)
        #expect(!operations.canDismissPull)
        operations.dismissPullProgress()
        #expect(operations.pullPresentation != nil)

        await gate.allow()
        await pull.value

        #expect(!operations.isPullActive)
        #expect(operations.canDismissPull)
        operations.dismissPullProgress()
        #expect(operations.pullPresentation == nil)
    }

    private func makeContext(
        session: @escaping () async throws -> any SSHSession,
        refresh: @escaping (DockerRefreshScope) async -> Void = { _ in }
    ) -> DockerContext {
        DockerContext(
            session: session, sudo: false, isUsable: true,
            report: { _ in }, refresh: refresh, reprobe: {}
        )
    }
}

private final class RecordingHistory: RunHistoryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: RunHistoryEntry] = [:]
    private var orderedIDs: [String] = []
    private(set) var recordedIDs: [String] = []
    private(set) var updatedIDs: [String] = []
    private let failRecord: Bool

    init(failRecord: Bool = false) {
        self.failRecord = failRecord
    }

    var entries: [RunHistoryEntry] {
        lock.withLock { orderedIDs.compactMap { stored[$0] } }
    }

    func record(_ entry: RunHistoryEntry) throws {
        if failRecord { throw SSHError.channelClosed }
        lock.withLock {
            stored[entry.id] = entry
            orderedIDs.append(entry.id)
            recordedIDs.append(entry.id)
        }
    }

    func update(_ entry: RunHistoryEntry) throws {
        lock.withLock {
            stored[entry.id] = entry
            updatedIDs.append(entry.id)
        }
    }

    func recoverPending() throws {}

    func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry] {
        entries.prefix(limit).map { $0 }
    }
}

private actor OperationGate {
    private var commands: [String] = []
    private var open = false
    private var firstCommandWaiter: CheckedContinuation<Void, Never>?
    private var openWaiter: CheckedContinuation<Void, Never>?

    func begin(_ command: String) -> Bool {
        commands.append(command)
        if commands.count == 1 {
            firstCommandWaiter?.resume()
            firstCommandWaiter = nil
            return true
        }
        return false
    }

    func waitForFirstCommand() async {
        guard commands.isEmpty else { return }
        await withCheckedContinuation { firstCommandWaiter = $0 }
    }

    func waitUntilOpen() async {
        guard !open else { return }
        await withCheckedContinuation { openWaiter = $0 }
    }

    func allow() {
        open = true
        openWaiter?.resume()
        openWaiter = nil
    }

    var commandCount: Int { commands.count }
}

private final class GatedOperationSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true
    private let gate: OperationGate

    init(gate: OperationGate) {
        self.gate = gate
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        if await gate.begin(command) { await gate.waitUntilOpen() }
        return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

private final class OperationSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true
    private let result: ExecResult
    private let throwsUnknown: Bool
    private let lock = NSLock()
    private var executeCount = 0
    private var commands: [String] = []

    init(
        result: ExecResult = ExecResult(exitCode: 0, stdout: Data(), stderr: Data()),
        throwsUnknown: Bool = false
    ) {
        self.result = result
        self.throwsUnknown = throwsUnknown
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        lock.withLock {
            executeCount += 1
            commands.append(command)
        }
        if throwsUnknown { throw SSHError.channelClosed }
        return result
    }

    var didExecute: Bool { lock.withLock { executeCount > 0 } }
    var executionCount: Int { lock.withLock { executeCount } }
    var lastCommand: String? { lock.withLock { commands.last } }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) { self.result }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

private final class PullSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true
    private let chunks: [String]
    private let finalResult: Result<ExecResult, SSHError>
    private let lock = NSLock()
    private var started = false

    init(chunks: [String], result: Result<ExecResult, SSHError>) {
        self.chunks = chunks
        finalResult = result
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    var didStart: Bool { lock.withLock { started } }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        lock.withLock { started = true }
        let output = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
            continuation.finish()
        }
        return SSHCommandStream(output: output) {
            try self.finalResult.get()
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

private final class GatedPullSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true
    private let gate: OperationGate

    init(gate: OperationGate) {
        self.gate = gate
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        _ = await gate.begin(command)
        return SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) { [gate] in
            await gate.waitUntilOpen()
            return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}
