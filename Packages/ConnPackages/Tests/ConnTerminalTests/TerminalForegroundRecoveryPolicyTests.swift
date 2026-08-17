import ConnSSH
import Foundation
import Testing
@testable import ConnTerminal

@Suite("TerminalForegroundRecoveryPolicy — 前台恢复候选")
struct TerminalForegroundRecoveryPolicyTests {
    @Test("健康或无法确认死亡的 connected 会话保持原状")
    func preservesConnectedSessionsWithoutAffirmativeFailure() {
        for health in [
            SSHPooledSessionHealth.absent,
            .connecting,
            .connected,
        ] {
            #expect(!TerminalForegroundRecoveryPolicy.shouldRecover(
                status: .connected,
                poolHealth: health
            ))
        }
    }

    @Test("仅池明确死亡时主动恢复 connected 会话")
    func recoversConnectedSessionOnlyWhenPoolIsDead() {
        #expect(TerminalForegroundRecoveryPolicy.shouldRecover(
            status: .connected,
            poolHealth: .disconnected
        ))
    }

    @Test("已经断开或正在恢复的会话继续进入恢复流程")
    func recoversKnownDisconnectedStates() {
        for status in [
            TerminalTabStatus.disconnected(message: "lost"),
            .reconnecting,
        ] {
            #expect(TerminalForegroundRecoveryPolicy.shouldRecover(
                status: status,
                poolHealth: .absent
            ))
        }
    }

    @Test("当前会话优先，其余按最近使用时间和稳定 ID 排序")
    func ordersCurrentTabFirstThenMostRecent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates = [
            TerminalForegroundRecoveryCandidate(
                id: "older",
                status: .disconnected(message: nil),
                poolHealth: .absent,
                lastUsedAt: base
            ),
            TerminalForegroundRecoveryCandidate(
                id: "current",
                status: .connected,
                poolHealth: .disconnected,
                lastUsedAt: base.addingTimeInterval(-100)
            ),
            TerminalForegroundRecoveryCandidate(
                id: "newer-b",
                status: .reconnecting,
                poolHealth: .connected,
                lastUsedAt: base.addingTimeInterval(10)
            ),
            TerminalForegroundRecoveryCandidate(
                id: "newer-a",
                status: .disconnected(message: nil),
                poolHealth: .connected,
                lastUsedAt: base.addingTimeInterval(10)
            ),
            TerminalForegroundRecoveryCandidate(
                id: "healthy",
                status: .connected,
                poolHealth: .connected,
                lastUsedAt: base.addingTimeInterval(20)
            ),
        ]

        #expect(TerminalForegroundRecoveryPolicy.orderedCandidateIDs(
            from: candidates,
            currentTabID: "current"
        ) == ["current", "newer-a", "newer-b", "older"])
    }
}
