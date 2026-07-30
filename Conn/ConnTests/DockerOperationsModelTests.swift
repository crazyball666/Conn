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

        await operations.removeImage(image)

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

        await operations.removeImage(image)

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

        #expect(action.confirmationWord == "DELETE")
        #expect(!action.accepts(confirmation: "delete"))
        #expect(action.accepts(confirmation: "DELETE"))
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
        lock.withLock { executeCount += 1 }
        if throwsUnknown { throw SSHError.channelClosed }
        return result
    }

    var didExecute: Bool { lock.withLock { executeCount > 0 } }

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
