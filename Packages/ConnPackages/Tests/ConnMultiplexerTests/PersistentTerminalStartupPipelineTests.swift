@testable import ConnMultiplexer
import Foundation
import Testing

@Suite("terminal startup pipeline")
struct TerminalStartupPipelineTests {
    @Test("runs stages in order and leaves committed resources alive")
    func runsStagesInOrder() async throws {
        let recorder = StartupPipelineRecorder()
        let pipeline = TerminalStartupPipeline(steps: [
            step("control", recorder: recorder),
            step("terminal", recorder: recorder),
            step("binding", recorder: recorder),
        ])

        try await pipeline.run()

        #expect(await recorder.values == [
            "run:control", "run:terminal", "run:binding",
        ])
    }

    @Test("attributes the failed stage and rolls earlier resources back in reverse order")
    func rollsBackInReverseOrder() async throws {
        let recorder = StartupPipelineRecorder()
        let pipeline = TerminalStartupPipeline(steps: [
            step("control", recorder: recorder),
            step("terminal", recorder: recorder),
            TerminalStartupStep(id: "binding") {
                await recorder.append("run:binding")
                throw StartupPipelineTestError.failed
            },
        ])

        do {
            try await pipeline.run()
            Issue.record("pipeline should fail")
        } catch let failure as TerminalStartupFailure {
            #expect(failure.stageID == "binding")
            #expect(failure.underlyingError as? StartupPipelineTestError == .failed)
        }

        #expect(await recorder.values == [
            "run:control", "run:terminal", "run:binding",
            "rollback:terminal", "rollback:control",
        ])
    }

    @Test("cancellation rolls completed stages back and remains cancellation")
    func cancellationRollsBackCompletedStages() async {
        let recorder = StartupPipelineRecorder()
        let pipeline = TerminalStartupPipeline(steps: [
            step("transport", recorder: recorder),
            TerminalStartupStep(id: "control") {
                await recorder.append("run:control")
                throw CancellationError()
            },
        ])

        do {
            try await pipeline.run()
            Issue.record("cancelled pipeline should fail")
        } catch is CancellationError {
            // Cancellation is intentionally not wrapped as a provider startup failure.
        } catch {
            Issue.record("pipeline must preserve CancellationError")
        }

        #expect(await recorder.values == [
            "run:transport", "run:control", "rollback:transport",
        ])
    }

    private func step(
        _ id: TerminalStartupStageID,
        recorder: StartupPipelineRecorder
    ) -> TerminalStartupStep {
        TerminalStartupStep(id: id) {
            await recorder.append("run:\(id.rawValue)")
            return TerminalStartupRollback {
                await recorder.append("rollback:\(id.rawValue)")
            }
        }
    }
}

private enum StartupPipelineTestError: Error, Equatable {
    case failed
}

private actor StartupPipelineRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
