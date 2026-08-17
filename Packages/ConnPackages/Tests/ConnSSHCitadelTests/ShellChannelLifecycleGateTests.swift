import ConnSSH
import Testing
@testable import ConnSSHCitadel

private struct GateTestError: Error {}

@Suite("ShellChannelLifecycleGate — PTY 就绪与终止")
struct ShellChannelLifecycleGateTests {
    @Test("就绪后迟到的建连失败不能再次结束 open")
    func readyWinsOverLateOpenFailure() async throws {
        let gate = ShellChannelLifecycleGate()
        let waiter = Task { try await gate.waitForReady() }
        await Task.yield()

        gate.markReady()
        gate.markOpenFailed(GateTestError())

        try await waiter.value
        #expect(gate.isWritable)
    }

    @Test("终止幂等且让 writer 失效")
    func terminationIsIdempotentAndDisablesWriter() {
        let gate = ShellChannelLifecycleGate()
        gate.markReady()
        #expect(gate.isWritable)

        gate.terminate()
        gate.terminate()

        #expect(!gate.isWritable)
    }

    @Test("就绪前失败会把同一错误交给等待的 open")
    func openFailureReachesWaiter() async {
        let gate = ShellChannelLifecycleGate()
        let waiter = Task { try await gate.waitForReady() }
        await Task.yield()

        gate.markOpenFailed(GateTestError())

        do {
            try await waiter.value
            Issue.record("open 应抛出建立失败")
        } catch {
            #expect(error is GateTestError)
        }
    }

    @Test("未就绪和已终止时都不可写")
    func writerIsUnavailableBeforeReadyAndAfterTermination() {
        let gate = ShellChannelLifecycleGate()
        #expect(!gate.isWritable)
        gate.markReady()
        gate.terminate()
        #expect(!gate.isWritable)
    }

    @Test("取消停止等待不会消费后续真正的终止信号")
    func cancelledStopWaiterDoesNotConsumeTermination() async {
        let gate = ShellChannelLifecycleGate()
        let cancelledWaiter = Task { await gate.waitForStop() }
        await Task.yield()
        cancelledWaiter.cancel()
        await cancelledWaiter.value

        let terminalWaiter = Task { await gate.waitForStop() }
        await Task.yield()
        gate.terminate()
        await terminalWaiter.value
    }
}
