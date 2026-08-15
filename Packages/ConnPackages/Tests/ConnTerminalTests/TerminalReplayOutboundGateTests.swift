import Testing
@testable import ConnTerminal

@Suite("TerminalReplayOutboundGate — 历史回放隔离")
struct TerminalReplayOutboundGateTests {
    @Test("历史回放期间拒绝终端协议回包，回放结束后恢复")
    func suppressesOnlyDuringTranscriptReplay() {
        let gate = TerminalReplayOutboundGate()

        #expect(gate.allowsTerminalDelegateOutput)

        gate.beginReplay()
        #expect(!gate.allowsTerminalDelegateOutput)

        gate.finishReplay()
        #expect(gate.allowsTerminalDelegateOutput)
    }
}
