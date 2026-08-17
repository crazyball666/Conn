import ConnSSH
import Foundation

struct TerminalForegroundRecoveryCandidate: Sendable, Equatable {
    let id: String
    let status: TerminalTabStatus
    let poolHealth: SSHPooledSessionHealth
    let lastUsedAt: Date
}

enum TerminalForegroundRecoveryPolicy {
    static func shouldRecover(
        status: TerminalTabStatus,
        poolHealth: SSHPooledSessionHealth
    ) -> Bool {
        switch status {
        case .disconnected, .reconnecting:
            true
        case .connected:
            poolHealth == .disconnected
        }
    }

    static func orderedCandidateIDs(
        from candidates: [TerminalForegroundRecoveryCandidate],
        currentTabID: String?
    ) -> [String] {
        candidates
            .filter { shouldRecover(status: $0.status, poolHealth: $0.poolHealth) }
            .sorted { lhs, rhs in
                let lhsIsCurrent = lhs.id == currentTabID
                let rhsIsCurrent = rhs.id == currentTabID
                if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
                if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
                return lhs.id < rhs.id
            }
            .map(\.id)
    }
}
