import ConnKit
import ConnMultiplexer
import Foundation
import Testing
@testable import ConnTerminal

private typealias Host = ConnKit.Host

private actor FlowPrepareGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting = false

    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while !waiting { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FlowCancellationProbe {
    private var started = false
    private var cancelled = false

    func run() async {
        started = true
        do {
            try await Task.sleep(for: .seconds(1))
        } catch is CancellationError {
            cancelled = true
        } catch {}
    }

    func waitUntilStarted() async {
        while !started { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func wasCancelled() -> Bool { cancelled }
}

@MainActor
private final class NewTerminalOperationsRecorder {
    var hostResult: [Host] = []
    var hostError: (any Error)?
    var candidateCalls = 0
    var workspaceCalls = 0
    var candidateResult: [PersistentBackendCandidate] = []
    var candidateOperation: (@MainActor (Host) async -> [PersistentBackendCandidate])?
    var workspaceResult: [RemoteWorkspaceSummary] = []
    var workspaceError: (any Error)?
    var existingBackend: TerminalLaunchBackend = .plainPTY
    var createBackend: TerminalLaunchBackend = .plainPTY
    var createBackendGate: FlowPrepareGate?
    var existingWorkspaceCalls: [RemoteWorkspaceRef] = []
    var createSelections: [PersistentWorkspaceCreateSelection] = []
    var prepareGate: FlowPrepareGate?
    var prepareResult: Result<Void, TerminalLaunchFailure> = .success(())
    var preparedRequests: [TerminalLaunchRequest] = []
    var cancelledAttempts: [TerminalLaunchAttemptID] = []
    var completion: NewTerminalFlowCompletion?

    var operations: NewTerminalFlowModel.Operations {
        NewTerminalFlowModel.Operations(
            loadHosts: { [weak self] in
                if let error = self?.hostError { throw error }
                return self?.hostResult ?? []
            },
            persistentBackendCandidates: { [weak self] host in
                self?.candidateCalls += 1
                if let candidateOperation = self?.candidateOperation {
                    return await candidateOperation(host)
                }
                return self?.candidateResult ?? []
            },
            persistentWorkspaceOptions: { [weak self] _, _ in
                self?.workspaceCalls += 1
                if let error = self?.workspaceError { throw error }
                return self?.workspaceResult ?? []
            },
            makeExistingBackend: { [weak self] _, workspace, _ in
                self?.existingWorkspaceCalls.append(workspace)
                return self?.existingBackend ?? .plainPTY
            },
            makeCreateBackend: { [weak self] _, selection, _ in
                self?.createSelections.append(selection)
                if let gate = self?.createBackendGate { await gate.wait() }
                return self?.createBackend ?? .plainPTY
            },
            beginLaunchAttempt: {
                TerminalLaunchAttemptID(rawValue: UUID())
            },
            prepareLaunch: { [weak self] request, _ in
                self?.preparedRequests.append(request)
                if let gate = self?.prepareGate { await gate.wait() }
                return self?.prepareResult ?? .success(())
            },
            commitLaunch: { _ in .success("tab-1") },
            cancelLaunch: { [weak self] attemptID in
                self?.cancelledAttempts.append(attemptID)
            }
        )
    }
}

@Suite("NewTerminalFlowModel")
@MainActor
struct NewTerminalFlowModelTests {
    @Test("选择普通 PTY 直接创建且不探测 persistent provider")
    func plainPTYDoesNotProbePersistentProviders() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )

        await model.selectPlainPTY()

        #expect(recorder.candidateCalls == 0)
        #expect(recorder.workspaceCalls == 0)
        #expect(recorder.preparedRequests.count == 1)
        #expect(recorder.preparedRequests.first?.backend == .plainPTY)
        #expect(recorder.completion == NewTerminalFlowCompletion(host: host, tabID: "tab-1"))
    }

    @Test("选择 persistent 后才探测并保留不可用候选的诊断")
    func persistentSelectionRetainsUnavailableCandidateDiagnostics() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        let unavailable = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-host-1",
            displayName: "tmux",
            availability: .unavailable,
            issue: .executableMissing
        )
        recorder.candidateResult = [unavailable]
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )

        await model.selectPersistent()

        #expect(recorder.candidateCalls == 1)
        #expect(recorder.workspaceCalls == 0)
        #expect(model.candidates == [unavailable])
        #expect(model.usableCandidates.isEmpty)
        #expect(model.phase == .providerSelection)
        #expect(model.errorMessage == PersistentTerminalError.executableMissing.userFacingDiagnosis)
    }

    @Test("单个可用 persistent 候选自动执行一次 Workspace 查询")
    func singleUsablePersistentCandidateLoadsOneWorkspaceSnapshot() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        let candidate = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-host-1",
            displayName: "tmux",
            availability: .available
        )
        let workspace = makeWorkspace(id: "$1", name: "main")
        recorder.candidateResult = [candidate]
        recorder.workspaceResult = [workspace]
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )

        await model.selectPersistent()

        #expect(recorder.candidateCalls == 1)
        #expect(recorder.workspaceCalls == 1)
        #expect(model.selectedCandidate == candidate)
        #expect(model.workspaces == [workspace])
        #expect(model.phase == .workspaceSelection)
    }

    @Test("非固定主机入口先加载主机并在选择后进入类型选择")
    func unfixedFlowSelectsHostBeforeTerminalType() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        recorder.hostResult = [host]
        let model = NewTerminalFlowModel(
            fixedHost: nil,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )

        model.start()
        model.selectHost(host)

        #expect(model.hosts == [host])
        #expect(model.selectedHost == host)
        #expect(model.phase == .terminalTypeSelection)
    }

    @Test("主机读取失败后可以在同一弹窗重试恢复")
    func hostSelectionCanRetryAfterLoadFailure() {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        recorder.hostError = PersistentTerminalError.transportClosed
        let model = NewTerminalFlowModel(
            fixedHost: nil,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )

        model.start()
        #expect(model.hosts.isEmpty)
        #expect(model.errorMessage != nil)

        recorder.hostError = nil
        recorder.hostResult = [host]
        model.start()

        #expect(model.hosts == [host])
        #expect(model.errorMessage == nil)
        #expect(model.phase == .hostSelection)
    }

    @Test("多个可用候选先选择 provider 再查询所选 Workspace")
    func multiplePersistentCandidatesRequireExplicitCandidateSelection() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        let first = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-default",
            displayName: "tmux default",
            availability: .available
        )
        let second = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-work",
            displayName: "tmux work",
            availability: .degraded
        )
        let workspace = makeWorkspace(id: "$2", name: "work")
        recorder.candidateResult = [first, second]
        recorder.workspaceResult = [workspace]
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )

        await model.selectPersistent()
        #expect(model.phase == .providerSelection)
        #expect(recorder.workspaceCalls == 0)

        await model.selectCandidate(second)

        #expect(recorder.workspaceCalls == 1)
        #expect(model.selectedCandidate == second)
        #expect(model.workspaces == [workspace])
    }

    @Test("手动刷新失败保留上一份 Workspace 快照并显示错误")
    func failedRefreshPreservesPreviousWorkspaceSnapshot() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        let candidate = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-host-1",
            displayName: "tmux",
            availability: .available
        )
        let workspace = makeWorkspace(id: "$1", name: "main")
        recorder.candidateResult = [candidate]
        recorder.workspaceResult = [workspace]
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        await model.selectPersistent()
        recorder.workspaceError = PersistentTerminalError.serverUnavailable

        await model.refresh()

        #expect(recorder.candidateCalls == 2)
        #expect(recorder.workspaceCalls == 2)
        #expect(model.workspaces == [workspace])
        #expect(model.errorMessage != nil)
        #expect(model.phase == .workspaceSelection)
    }

    @Test("进入已有 Workspace 使用精确 descriptor 创建 persistent Tab")
    func attachingWorkspaceUsesPersistentBackendDescriptor() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        let candidate = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-host-1",
            displayName: "tmux",
            availability: .available
        )
        let workspace = makeWorkspace(id: "$1", name: "main")
        let descriptor = makeDescriptor(workspace: workspace.workspace)
        recorder.candidateResult = [candidate]
        recorder.workspaceResult = [workspace]
        recorder.existingBackend = .persistent(descriptor)
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        await model.selectPersistent()

        await model.attach(workspace)

        #expect(recorder.existingWorkspaceCalls == [workspace.workspace])
        #expect(recorder.preparedRequests.last?.backend == .persistent(descriptor))
        #expect(recorder.completion?.tabID == "tab-1")
    }

    @Test("新建 Workspace 使用显式 create selection")
    func creatingWorkspaceUsesExplicitCreateSelection() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        let candidate = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-host-1",
            displayName: "tmux",
            availability: .degraded
        )
        let descriptor = makeDescriptor(
            workspace: RemoteWorkspaceRef(
                workspaceID: "$new",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            )
        )
        recorder.candidateResult = [candidate]
        recorder.createBackend = .persistent(descriptor)
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        await model.selectPersistent()

        await model.createWorkspace(name: "  ops  ")

        #expect(recorder.createSelections == [PersistentWorkspaceCreateSelection(name: "ops")])
        #expect(recorder.preparedRequests.last?.backend == .persistent(descriptor))
        #expect(recorder.completion?.tabID == "tab-1")
    }

    @Test("进入 persistent Workspace 失败时保留 Workspace 页面和快照")
    func failedPersistentAttachPreservesWorkspaceSelection() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = NewTerminalOperationsRecorder()
        let candidate = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-host-1",
            displayName: "tmux",
            availability: .available
        )
        let workspace = makeWorkspace(id: "$1", name: "main")
        recorder.candidateResult = [candidate]
        recorder.workspaceResult = [workspace]
        recorder.existingBackend = .persistent(makeDescriptor(workspace: workspace.workspace))
        recorder.prepareResult = .failure(TerminalLaunchFailure(message: "attach failed"))
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        await model.selectPersistent()

        await model.attach(workspace)

        #expect(model.phase == .workspaceSelection)
        #expect(model.workspaces == [workspace])
        #expect(model.errorMessage == "attach failed")
        #expect(recorder.completion == nil)
    }

    @Test("关闭流程会取消正在 prepare 的 attempt 且忽略迟到成功")
    func closingFlowCancelsPreparingAttemptAndIgnoresLateSuccess() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let gate = FlowPrepareGate()
        let recorder = NewTerminalOperationsRecorder()
        recorder.prepareGate = gate
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        let launch = Task { await model.selectPlainPTY() }
        await gate.waitUntilBlocked()

        let cleanup = model.closeImmediately()
        await gate.release()
        await launch.value
        await cleanup?.value

        #expect(recorder.cancelledAttempts.count >= 1)
        #expect(recorder.completion == nil)
    }

    @Test("关闭流程会取消正在执行的 provider 探测任务")
    func closingFlowCancelsProviderProbeTask() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let probe = FlowCancellationProbe()
        let recorder = NewTerminalOperationsRecorder()
        recorder.candidateOperation = { _ in
            await probe.run()
            return []
        }
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        let selection = Task { await model.selectPersistent() }
        await probe.waitUntilStarted()

        let cleanup = model.closeImmediately()
        await selection.value
        await cleanup?.value

        #expect(await probe.wasCancelled())
        #expect(recorder.completion == nil)
    }

    @Test("关闭流程会隔离不响应取消的迟到 Workspace 创建结果")
    func closingFlowRejectsLateWorkspaceCreationResult() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let candidate = PersistentBackendCandidate(
            providerID: "tmux",
            profileID: "tmux-host-1",
            displayName: "tmux",
            availability: .degraded
        )
        let gate = FlowPrepareGate()
        let recorder = NewTerminalOperationsRecorder()
        recorder.candidateResult = [candidate]
        recorder.createBackendGate = gate
        let model = NewTerminalFlowModel(
            fixedHost: host,
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        await model.selectPersistent()
        let creation = Task { await model.createWorkspace(name: "ops") }
        await gate.waitUntilBlocked()

        let cleanup = model.closeImmediately()
        await gate.release()
        await creation.value
        await cleanup?.value

        #expect(recorder.preparedRequests.isEmpty)
        #expect(recorder.completion == nil)
    }
}

private func makeWorkspace(id: String, name: String) -> RemoteWorkspaceSummary {
    RemoteWorkspaceSummary(
        workspace: RemoteWorkspaceRef(
            workspaceID: id,
            instancePayloadVersion: 1,
            providerInstancePayload: Data()
        ),
        name: name,
        occupancy: RemoteWorkspaceOccupancy(
            affectedAttachmentCount: nil,
            observedAt: .now,
            freshness: .fresh
        )
    )
}

private func makeDescriptor(workspace: RemoteWorkspaceRef) -> PersistentAttachmentDescriptor {
    PersistentAttachmentDescriptor(
        providerID: "tmux",
        profileID: "tmux-host-1",
        workspace: workspace,
        payloadVersion: 1,
        providerPayload: Data()
    )
}
