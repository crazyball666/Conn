import Foundation
import Testing

private enum BoundedAcceptanceOperationError: Error, Equatable {
    case timedOut
    case cleanupTimedOut
}
private enum AcceptancePrimaryOutcome<Value: Sendable>: @unchecked Sendable {
    case success(Value)
    case failure(any Error)
    case timedOut
    case cancelled
}

private enum AcceptanceCleanupOutcome: Sendable {
    case finished
    case timedOut
}

private actor AcceptanceOneShot<Outcome: Sendable> {
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private actor BoundedAcceptanceCleanup {
    private let action: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    func start() -> Task<Void, Never> {
        if let task { return task }
        let action = self.action
        // Cleanup must not inherit cancellation from the timed-out/cancelled caller.
        let task = Task.detached { await action() }
        self.task = task
        return task
    }
}

private actor AcceptanceSessionCloseOwner {
    private let action: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    func close() async {
        await start().value
    }

    func close(timeout: Duration) async -> Bool {
        await waitForAcceptanceTask(start(), timeout: timeout)
    }

    private func start() -> Task<Void, Never> {
        if let task { return task }
        let action = self.action
        let task = Task.detached { await action() }
        self.task = task
        return task
    }
}

private typealias AcceptanceCleanupAction = @Sendable () async -> Void

private actor AcceptanceCleanupStack {
    private var actions: [AcceptanceCleanupAction]
    private var task: Task<Void, Never>?

    init(actions: [AcceptanceCleanupAction] = []) {
        self.actions = actions
    }

    func register(_ action: @escaping AcceptanceCleanupAction) async {
        guard task != nil else {
            actions.append(action)
            return
        }
        // A subsystem can finish opening while parent-session teardown is already in flight.
        // Close it immediately on a best-effort basis. This late close may overlap the parent
        // close; strict LIFO is impossible because the parent close is what unblocks the open.
        await Task.detached { await action() }.value
    }

    func closeAll() async {
        let task: Task<Void, Never>
        if let existing = self.task {
            task = existing
        } else {
            // Resources are registered after the session, so LIFO closes them first.
            let actions = Array(self.actions.reversed())
            self.actions.removeAll()
            let created = Task.detached {
                for action in actions {
                    await action()
                }
            }
            self.task = created
            task = created
        }
        await task.value
    }
}

private func withBoundedAcceptanceOperation<Result: Sendable>(
    timeout: Duration,
    cleanupTimeout: Duration,
    cleanup: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let cleanup = BoundedAcceptanceCleanup(action: cleanup)
    let primary = AcceptanceOneShot<AcceptancePrimaryOutcome<Result>>()
    // These tasks are intentionally unstructured: helper return must never join work that
    // ignores cancellation. Real session close should unblock Citadel; a pathological detached
    // task that ignores both cancellation and cleanup can only be reclaimed at process exit.
    let operationTask = Task.detached {
        do {
            await primary.resolve(.success(try await operation()))
        } catch {
            await primary.resolve(.failure(error))
        }
    }
    let timeoutTask = Task.detached {
        do {
            try await Task.sleep(for: timeout)
            await primary.resolve(.timedOut)
        } catch {
            // Losing timer cancellation is expected.
        }
    }

    let outcome = await withTaskCancellationHandler {
        await primary.wait()
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        _ = Task.detached { await primary.resolve(.cancelled) }
    }
    operationTask.cancel()
    timeoutTask.cancel()

    guard await runBoundedAcceptanceCleanup(cleanup, timeout: cleanupTimeout) else {
        // The detached cleanup task was cancelled but may survive if it also ignores cancellation.
        throw BoundedAcceptanceOperationError.cleanupTimedOut
    }
    try Task.checkCancellation()

    switch outcome {
    case let .success(result):
        return result
    case let .failure(error):
        throw error
    case .timedOut:
        throw BoundedAcceptanceOperationError.timedOut
    case .cancelled:
        throw CancellationError()
    }
}

private func runBoundedAcceptanceCleanup(
    _ cleanup: BoundedAcceptanceCleanup,
    timeout: Duration
) async -> Bool {
    let cleanupTask = await cleanup.start()
    return await waitForAcceptanceTask(cleanupTask, timeout: timeout)
}

private func waitForAcceptanceTask(
    _ task: Task<Void, Never>,
    timeout: Duration
) async -> Bool {
    let completion = AcceptanceOneShot<AcceptanceCleanupOutcome>()
    let observerTask = Task.detached {
        await task.value
        await completion.resolve(.finished)
    }
    let timeoutTask = Task.detached {
        do {
            try await Task.sleep(for: timeout)
            await completion.resolve(.timedOut)
        } catch {
            // Losing timer cancellation is expected.
        }
    }

    let outcome = await completion.wait()
    observerTask.cancel()
    timeoutTask.cancel()
    if case .timedOut = outcome {
        task.cancel()
        return false
    }
    return true
}

@Suite("bounded operation cleanup")
struct BoundedOperationCleanupTests {
    @Test("success awaits async cleanup exactly once")
    func successAwaitsCleanup() async throws {
        let probe = BoundedOperationProbe()

        let value = try await withBoundedAcceptanceOperation(
            timeout: .seconds(1),
            cleanupTimeout: .seconds(1),
            cleanup: { await probe.cleanup() }
        ) {
            "done"
        }

        #expect(value == "done")
        #expect(await probe.cleanupCount == 1)
        #expect(await probe.cleanupFinished)
    }

    @Test("operation error awaits async cleanup before propagating")
    func errorAwaitsCleanup() async throws {
        let probe = BoundedOperationProbe()

        do {
            let _: String = try await withBoundedAcceptanceOperation(
                timeout: .seconds(1),
                cleanupTimeout: .seconds(1),
                cleanup: { await probe.cleanup() }
            ) {
                throw BoundedOperationProbeError.operationFailed
            }
            Issue.record("Expected operation failure")
        } catch let error as BoundedOperationProbeError {
            #expect(error == .operationFailed)
        }

        #expect(await probe.cleanupCount == 1)
        #expect(await probe.cleanupFinished)
    }

    @Test("timeout cleans up before throwing and unblocks cancellation-ignoring work")
    func timeoutCleansUpAndUnblocksWork() async throws {
        let probe = BoundedOperationProbe()

        do {
            _ = try await withBoundedAcceptanceOperation(
                timeout: .milliseconds(50),
                cleanupTimeout: .seconds(1),
                cleanup: { await probe.cleanup() }
            ) {
                await probe.waitUntilCleanup()
                return "unblocked"
            }
            Issue.record("Expected bounded operation timeout")
        } catch let error as BoundedAcceptanceOperationError {
            #expect(error == .timedOut)
        }

        #expect(await probe.cleanupCount == 1)
        #expect(await probe.cleanupFinished)
    }

    @Test("parent cancellation triggers cleanup and reports cancellation")
    func cancellationCleansUpAndUnblocksWork() async throws {
        let probe = BoundedOperationProbe()
        let operation = Task {
            try await withBoundedAcceptanceOperation(
                timeout: .seconds(30),
                cleanupTimeout: .seconds(1),
                cleanup: { await probe.cleanup() }
            ) {
                await probe.waitUntilCleanup()
                return "unblocked"
            }
        }
        do {
            try await probe.waitUntilOperationBlocked(timeout: .seconds(1))
        } catch {
            operation.cancel()
            _ = await operation.result
            throw error
        }

        operation.cancel()

        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await probe.cleanupCount == 1)
        #expect(await probe.cleanupFinished)
    }

    @Test("hanging cleanup returns a distinct error within its secondary deadline")
    func hangingCleanupIsBounded() async throws {
        let probe = DetachedWorkProbe()
        let failSafe = Task {
            try? await Task.sleep(for: .seconds(2))
            await probe.releaseCleanup()
        }
        let started = ContinuousClock.now

        do {
            _ = try await withBoundedAcceptanceOperation(
                timeout: .seconds(1),
                cleanupTimeout: .milliseconds(50),
                cleanup: { await probe.waitForCleanupRelease() }
            ) {
                "done"
            }
            Issue.record("Expected cleanup timeout")
        } catch let error as BoundedAcceptanceOperationError {
            #expect(error == .cleanupTimedOut)
        }

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await probe.cleanupCount == 1)
        await probe.releaseCleanup()
        failSafe.cancel()
        await failSafe.value
    }

    @Test("operation ignoring cancellation and cleanup cannot delay timeout return")
    func uncooperativeOperationDoesNotDelayTimeout() async throws {
        let probe = DetachedWorkProbe()
        let failSafe = Task {
            try? await Task.sleep(for: .seconds(2))
            await probe.releaseOperation()
        }
        let operation = Task {
            try await withBoundedAcceptanceOperation(
                timeout: .milliseconds(50),
                cleanupTimeout: .milliseconds(100),
                cleanup: { await probe.recordCleanup() }
            ) {
                await probe.waitForOperationRelease()
                return "released"
            }
        }
        do {
            try await probe.waitUntilOperationStarts(timeout: .seconds(1))
        } catch {
            await probe.releaseOperation()
            failSafe.cancel()
            _ = await operation.result
            throw error
        }
        let started = ContinuousClock.now

        do {
            _ = try await operation.value
            Issue.record("Expected operation timeout")
        } catch let error as BoundedAcceptanceOperationError {
            #expect(error == .timedOut)
        }

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await probe.cleanupCount == 1)
        await probe.releaseOperation()
        failSafe.cancel()
        await failSafe.value
    }

    @Test("session close owner memoizes one close task")
    func sessionCloseOwnerClosesExactlyOnce() async {
        let probe = SessionCloseProbe()
        let owner = AcceptanceSessionCloseOwner {
            await probe.closeSession()
        }

        async let first: Void = owner.close()
        async let second: Void = owner.close()
        _ = await (first, second)
        await owner.close()

        #expect(await probe.closeCount == 1)
    }

    @Test("pre-registered resources close in strict LIFO order")
    func preRegisteredResourcesCloseBeforeSession() async {
        let probe = CleanupStackProbe()
        let cleanup = AcceptanceCleanupStack(actions: [
            { await probe.record("session-close") },
        ])
        await cleanup.register { await probe.record("resource-close") }

        await cleanup.closeAll()

        #expect(await probe.events == ["resource-close", "session-close"])
    }

    @Test("late resource closes during parent close and cleanup waits safely")
    func lateResourceRegistrationIsCleanedUp() async throws {
        let probe = CleanupStackProbe()
        let cleanup = AcceptanceCleanupStack(actions: [
            { await probe.closeSession() },
        ])
        let failSafe = Task {
            try? await Task.sleep(for: .seconds(2))
            await probe.finishSessionCleanup()
        }
        let helper = Task {
            try await withBoundedAcceptanceOperation(
                timeout: .milliseconds(50),
                cleanupTimeout: .seconds(1),
                cleanup: { await cleanup.closeAll() }
            ) {
                // Models Citadel open ignoring cancellation until parent session close starts.
                await probe.waitForSessionCleanupToStart()
                await cleanup.register { await probe.record("resource-close") }
                return "late-open"
            }
        }
        do {
            try await probe.waitUntilSessionCleanupStarts(timeout: .seconds(1))
            try await probe.waitUntilEventCount(2, timeout: .seconds(1))
        } catch {
            await probe.finishSessionCleanup()
            _ = await helper.result
            failSafe.cancel()
            await failSafe.value
            throw error
        }

        #expect(await probe.events == ["session-start", "resource-close"])
        await probe.finishSessionCleanup()
        do {
            _ = try await helper.value
            Issue.record("Expected operation timeout")
        } catch let error as BoundedAcceptanceOperationError {
            #expect(error == .timedOut)
        }
        failSafe.cancel()
        await failSafe.value
        #expect(await probe.events == ["session-start", "resource-close", "session-finish"])
    }
}
private enum BoundedOperationProbeError: Error, Equatable {
    case operationFailed
    case readinessTimedOut
}

private actor BoundedOperationProbe {
    private(set) var cleanupCount = 0
    private(set) var cleanupFinished = false
    private var operationBlocked = false
    private var cleanupStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilCleanup() async {
        operationBlocked = true
        guard !cleanupStarted else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilOperationBlocked(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !operationBlocked {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BoundedOperationProbeError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func cleanup() async {
        cleanupCount += 1
        try? await Task.sleep(for: .milliseconds(20))
        cleanupStarted = true
        cleanupFinished = true
        continuation?.resume()
        continuation = nil
    }
}

private actor DetachedWorkProbe {
    private(set) var cleanupCount = 0
    private var operationStarted = false
    private var operationReleased = false
    private var cleanupReleased = false
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var cleanupContinuation: CheckedContinuation<Void, Never>?

    func waitForOperationRelease() async {
        operationStarted = true
        guard !operationReleased else { return }
        await withCheckedContinuation { operationContinuation = $0 }
    }

    func waitUntilOperationStarts(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !operationStarted {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BoundedOperationProbeError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseOperation() {
        operationReleased = true
        operationContinuation?.resume()
        operationContinuation = nil
    }

    func waitForCleanupRelease() async {
        cleanupCount += 1
        guard !cleanupReleased else { return }
        await withCheckedContinuation { cleanupContinuation = $0 }
    }

    func recordCleanup() {
        cleanupCount += 1
    }

    func releaseCleanup() {
        cleanupReleased = true
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }
}

private actor CleanupStackProbe {
    private(set) var events: [String] = []
    private var sessionCleanupStarted = false
    private var sessionStartContinuation: CheckedContinuation<Void, Never>?
    private var sessionCleanupContinuation: CheckedContinuation<Void, Never>?

    func closeSession() async {
        sessionCleanupStarted = true
        events.append("session-start")
        sessionStartContinuation?.resume()
        sessionStartContinuation = nil
        await withCheckedContinuation { sessionCleanupContinuation = $0 }
        events.append("session-finish")
    }

    func waitForSessionCleanupToStart() async {
        guard !sessionCleanupStarted else { return }
        await withCheckedContinuation { sessionStartContinuation = $0 }
    }

    func waitUntilSessionCleanupStarts(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !sessionCleanupStarted {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BoundedOperationProbeError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilEventCount(_ count: Int, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while events.count < count {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BoundedOperationProbeError.readinessTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func record(_ event: String) {
        events.append(event)
    }

    func finishSessionCleanup() {
        sessionCleanupStarted = true
        sessionStartContinuation?.resume()
        sessionStartContinuation = nil
        sessionCleanupContinuation?.resume()
        sessionCleanupContinuation = nil
    }
}

private actor SessionCloseProbe {
    private(set) var closeCount = 0

    func closeSession() async {
        closeCount += 1
        try? await Task.sleep(for: .milliseconds(20))
    }
}
