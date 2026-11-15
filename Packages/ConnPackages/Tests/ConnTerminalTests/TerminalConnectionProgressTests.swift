import ConnKit
import ConnSSH
import Testing
@testable import ConnTerminal

@Suite("连接进度回归")
@MainActor
struct TerminalConnectionProgressTests {
    private func center() -> TerminalConnectionProgressCenter {
        let center = TerminalConnectionProgressCenter()
        center.begin(
            host: Host(name: "fixture", address: "127.0.0.1", username: "fixture",
                       privateNetworkProfileID: "fixture"),
            kind: .reconnect, activityID: "tab", connectionRef: "attempt"
        )
        return center
    }

    private func sample(
        _ phase: String,
        outcome: ConnectionPhaseSample.Outcome = .success,
        ref: String = "attempt",
        durationMs: Int = 12,
        errorCategory: String = "",
        errorText: String = "",
        isFinalFailure: Bool = true
    ) -> ConnectionPhaseSample {
        .init(
            context: .init(connectionRef: ref, routeReused: true),
            phase: phase,
            durationMs: durationMs,
            outcome: outcome,
            errorCategory: errorCategory,
            errorText: errorText,
            isFinalFailure: isFinalFailure
        )
    }

    @Test func reusedRouteAdvancesPastUnreportedSetupWithoutInventingDurations() throws {
        let center = center()
        center.record(sample("route_setup"))
        let activity = try #require(center.activity(forID: "tab"))
        #expect(activity.steps.prefix(4).allSatisfy { $0.state == .completed })
        #expect(activity.steps.filter { $0.state == .active }.map(\.id) == [.socks])
        #expect(activity.steps.prefix(3).allSatisfy { $0.durationMs == nil })
        #expect(activity.steps.first { $0.id == .route }?.durationMs == 12)
    }

    @Test func lateAndDuplicatePhasesNeverMoveProgressBackwards() throws {
        let center = center()
        center.record(sample("socks_proxy"))
        center.record(sample("route_setup"))
        center.record(sample("socks_proxy", durationMs: 24))
        let activity = try #require(center.activity(forID: "tab"))
        #expect(activity.steps.filter { $0.state == .active }.map(\.id) == [.network])
        #expect(activity.steps.first { $0.id == .route }?.durationMs == 12)
        #expect(activity.steps.first { $0.id == .socks }?.durationMs == 12)
    }

    @Test func cancelledSampleDoesNotBecomeSuccess() {
        let center = center()
        center.record(sample("route_setup", outcome: .cancelled))
        #expect(center.activity(forID: "tab")?.state == .cancelled)
        #expect(center.activity(forID: "tab")?.activeStep == nil)
    }

    @Test func handshakeAuthenticationErrorPreservesFailedStepAndUnmeasuredPredecessors() throws {
        let center = center()
        center.record(sample("ssh_handshake", outcome: .failure, errorCategory: "auth", errorText: "bad key"))
        let activity = try #require(center.activity(forID: "tab"))
        #expect(activity.failedStep?.id == .authentication)
        #expect(activity.failedStep?.durationMs == 12)
        #expect(activity.failedStep?.detail == "bad key")
        #expect(activity.steps.prefix(6).allSatisfy { $0.state == .completed && $0.durationMs == nil })
        #expect(activity.activeStep == nil)
    }

    @Test func coordinatorFailureCannotOverwriteRouteSampleDiagnosis() throws {
        let center = center()
        center.record(sample("route_setup", outcome: .failure, errorText: "original route error"))
        center.fail(forID: "tab", step: .network, message: "later coordinator error")
        let activity = try #require(center.activity(forID: "tab"))
        #expect(activity.failedStep?.id == .route)
        #expect(activity.failedStep?.detail == "original route error")
        #expect(activity.errorMessage == "original route error")
        #expect(activity.logs.last?.message == "original route error")
    }

    @Test func retryableHandshakeFailureLetsTheSameActivityConnect() throws {
        let center = center()
        center.record(sample("ssh_handshake", outcome: .failure, errorText: "first attempt",
                             isFinalFailure: false))
        let retrying = try #require(center.activity(forID: "tab"))
        #expect(retrying.state == .connecting)
        #expect(retrying.activeStep?.id == .network)
        #expect(retrying.failedStep == nil)
        #expect(retrying.errorMessage == nil)
        #expect(retrying.logs.last?.message == "first attempt")

        center.record(sample("ssh_handshake"))
        center.finish(forID: "tab")

        #expect(center.activity(forID: "tab")?.state == .connected)
        #expect(center.activity(forID: "tab")?.failedStep == nil)
    }

    @Test func exhaustedHandshakeRetriesPreserveFinalFailure() throws {
        let center = center()
        center.record(sample("ssh_handshake", outcome: .failure, errorText: "first attempt",
                             isFinalFailure: false))
        center.record(sample("ssh_handshake", outcome: .failure, errorText: "last attempt"))
        center.finish(forID: "tab")

        let failed = try #require(center.activity(forID: "tab"))
        #expect(failed.state == .failed)
        #expect(failed.failedStep?.id == .network)
        #expect(failed.errorMessage == "last attempt")
        #expect(failed.logs.suffix(2).map(\.message) == ["first attempt", "last attempt"])
    }

    @Test func absentStepActivationKeepsCurrentStepActive() throws {
        let center = TerminalConnectionProgressCenter()
        center.begin(
            host: Host(name: "fixture", address: "127.0.0.1", username: "fixture"),
            kind: .connect,
            activityID: "tab"
        )
        let before = try #require(center.activity(forID: "tab"))
        center.activate(.route, forID: "tab")
        #expect(center.activity(forID: "tab") == before)
    }

    @Test(arguments: [TerminalConnectionActivityState.failed, .cancelled, .connected])
    func terminalOutcomesRejectLateMutations(_ outcome: TerminalConnectionActivityState) throws {
        let center = center()
        switch outcome {
        case .failed: center.fail(forID: "tab", message: "fixture error")
        case .cancelled: center.cancel(forID: "tab")
        case .connected: center.finish(forID: "tab")
        case .connecting: break
        }
        let ended = try #require(center.activity(forID: "tab"))
        center.record(sample("terminal_ready"))
        center.record(sample("ssh_handshake", outcome: .failure))
        center.activate(.shell, forID: "tab")
        center.completePendingRouteStages(forID: "tab")
        center.complete(.ready, forID: "tab")
        center.finish(forID: "tab")
        center.cancel(forID: "tab")
        center.fail(forID: "tab", message: "late failure")
        #expect(center.activity(forID: "tab") == ended)
    }

    @Test func readySampleWaitsForCoordinatorCommit() {
        let center = center()
        center.record(sample("terminal_ready"))
        #expect(center.activity(forID: "tab")?.state == .connecting)
        center.finish(forID: "tab")
        #expect(center.activity(forID: "tab")?.state == .connected)
    }

    @Test func previousAttemptCannotMutateRetry() throws {
        let center = center()
        let before = try #require(center.activity(forID: "tab"))
        center.record(sample("route_setup", ref: "old-attempt"))
        #expect(center.activity(forID: "tab") == before)
    }
}
