import ConnKit
import Foundation
import Testing
@testable import ConnTerminal

private actor ExplicitPrepareGate {
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

@MainActor
private final class ExplicitLaunchRecorder {
    var preparedRequests: [TerminalLaunchRequest] = []
    var cancelledAttempts: [TerminalLaunchAttemptID] = []
    var prepareGate: ExplicitPrepareGate?
    var completion: NewTerminalFlowCompletion?

    var operations: NewTerminalFlowModel.Operations {
        .init(
            loadHosts: { [] },
            persistentBackendOptions: { [] },
            persistentWorkspaceOptions: { _, _ in [] },
            makeExistingBackend: { _, _, _ in throw CancellationError() },
            makeCreateBackend: { _, _, _ in throw CancellationError() },
            beginLaunchAttempt: { TerminalLaunchAttemptID(rawValue: UUID()) },
            prepareLaunch: { [weak self] request, _ in
                self?.preparedRequests.append(request)
                if let gate = self?.prepareGate { await gate.wait() }
                return .success(())
            },
            commitLaunch: { _ in .success("docker-tab") },
            cancelLaunch: { [weak self] attemptID in
                self?.cancelledAttempts.append(attemptID)
            }
        )
    }
}

@Suite("ExplicitTerminalLaunchModel")
@MainActor
struct ExplicitTerminalLaunchModelTests {
    @Test("显式入口在源页面提交完整 request 后才完成导航结果")
    func explicitLaunchPreservesRequestUntilCommit() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let recorder = ExplicitLaunchRecorder()
        let model = ExplicitTerminalLaunchModel(
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        let request = TerminalLaunchRequest(
            host: host,
            policy: .createNew,
            source: .docker(containerName: "api"),
            initialCommand: "docker exec -it api sh",
            replayInitialCommandOnReconnect: true
        )

        await model.launch(request)

        #expect(recorder.preparedRequests.count == 1)
        #expect(recorder.preparedRequests.first?.source == .docker(containerName: "api"))
        #expect(recorder.preparedRequests.first?.initialCommand == "docker exec -it api sh")
        #expect(recorder.preparedRequests.first?.replayInitialCommandOnReconnect == true)
        #expect(recorder.completion == NewTerminalFlowCompletion(host: host, tabID: "docker-tab"))
    }

    @Test("显式入口离开源页面后取消 attempt 并忽略迟到成功")
    func closingExplicitLaunchPreventsLateNavigation() async {
        let host = Host(id: "host-1", name: "web", address: "10.0.0.1", username: "root")
        let gate = ExplicitPrepareGate()
        let recorder = ExplicitLaunchRecorder()
        recorder.prepareGate = gate
        let model = ExplicitTerminalLaunchModel(
            operations: recorder.operations,
            onCompleted: { recorder.completion = $0 }
        )
        let launch = Task {
            await model.launch(TerminalLaunchRequest(
                host: host,
                policy: .createNew,
                source: .script(title: "health"),
                initialCommand: "uptime"
            ))
        }
        await gate.waitUntilBlocked()

        let cleanup = model.closeImmediately()
        await gate.release()
        await launch.value
        await cleanup?.value

        #expect(!recorder.cancelledAttempts.isEmpty)
        #expect(recorder.completion == nil)
    }
}
