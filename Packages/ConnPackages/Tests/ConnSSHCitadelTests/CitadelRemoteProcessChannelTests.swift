@testable import ConnSSHCitadel
import Foundation
import Testing

@Suite("Citadel remote process lifecycle")
struct CitadelRemoteProcessChannelTests {
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

private actor PumpCancellationRecorder {
    private(set) var wasRecorded = false

    func record() {
        wasRecorded = true
    }
}
