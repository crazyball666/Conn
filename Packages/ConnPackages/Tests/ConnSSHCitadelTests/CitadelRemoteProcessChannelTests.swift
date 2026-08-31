@testable import ConnSSHCitadel
import Foundation
import NIOCore
import Testing

@Suite("Citadel remote process lifecycle")
struct CitadelRemoteProcessChannelTests {
    @Test("没有 SSH exit-status 的 EOF 不得被当作成功退出")
    func transportEOFIsNotSuccessfulExit() {
        let transportEOF = CitadelRemoteProcessChannel.pumpOutcome(forExitCode: nil)
        if case .transportClosed = transportEOF {
            // Expected: a closed SSH transport is not a successful remote exit.
        } else {
            Issue.record("没有 exit-status 的 EOF 必须保留为 transport close")
        }

        for (exitCode, expected) in [(0, Int32(0)), (75, Int32(75))] {
            guard case let .exited(actual) = CitadelRemoteProcessChannel.pumpOutcome(
                forExitCode: exitCode
            ) else {
                Issue.record("已有 SSH exit-status 时必须保留为 exited")
                continue
            }
            #expect(actual == expected)
        }
    }

    @Test("server close racing local cleanup remains a successful process exit")
    func remoteCloseRaceAfterExitIsNotFailure() {
        #expect(CitadelRemoteProcessChannel.normalizedProcessError(
            ChannelError.alreadyClosed,
            after: .exited(0)
        ) == nil)
        #expect(CitadelRemoteProcessChannel.normalizedProcessError(
            ChannelError.alreadyClosed,
            after: .stopped
        ) != nil)
        #expect(CitadelRemoteProcessChannel.normalizedProcessError(
            ProcessLifecycleTestError.failed,
            after: .exited(0)
        ) != nil)
    }

    @Test("local stop cancels and joins the process output pump")
    func localStopCancelsPump() async {
        let (pumpStarted, pumpStartedContinuation) = AsyncStream<Void>.makeStream()
        let (stopRequested, stopRequestedContinuation) = AsyncStream<Void>.makeStream()
        let cancellation = PumpCancellationRecorder()

        let race = Task {
            await CitadelRemoteProcessChannel.waitForPumpOrStop(
                pump: {
                    pumpStartedContinuation.yield()
                    pumpStartedContinuation.finish()
                    do {
                        try await Task.sleep(for: .seconds(1))
                        return .exited(0)
                    } catch {
                        await cancellation.record()
                        return .stopped
                    }
                },
                stop: {
                    for await _ in stopRequested { return }
                }
            )
        }

        for await _ in pumpStarted { break }
        stopRequestedContinuation.yield()
        stopRequestedContinuation.finish()

        let outcome = await race.value
        if case .stopped = outcome {
            // Expected.
        } else {
            Issue.record("local stop must win the process race")
        }
        #expect(await cancellation.wasRecorded)
    }

    @Test("remote process completion cancels the local-stop waiter")
    func remoteCompletionCancelsStopWaiter() async {
        let gate = ShellChannelLifecycleGate()

        let outcome = await CitadelRemoteProcessChannel.waitForPumpOrStop(
            pump: {
                try? await Task.sleep(for: .milliseconds(10))
                return .exited(0)
            },
            stop: {
                await gate.waitForStop()
            }
        )

        if case .exited(0) = outcome {
            // Expected.
        } else {
            Issue.record("remote completion must win the process race")
        }
    }
}

private enum ProcessLifecycleTestError: Error {
    case failed
}

private actor PumpCancellationRecorder {
    private(set) var wasRecorded = false

    func record() {
        wasRecorded = true
    }
}
