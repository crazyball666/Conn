import Testing
@testable import Conn

@Suite("Snippet compatibility task registry")
@MainActor
struct SnippetCompatibilityTaskRegistryTests {
    @Test("replacing a host task cancels the old task and retains the replacement")
    func replaceCancelsOldTask() async {
        let registry = SnippetCompatibilityTaskRegistry()
        let probe = CompatibilityTaskProbe()

        registry.replace(hostID: "host") { _ in
            await probe.run("old")
        }
        await probe.waitUntilStarted("old")

        registry.replace(hostID: "host") { _ in
            await probe.run("new")
        }
        await probe.waitUntilStarted("new")
        await probe.waitUntilCancelled("old")
        await probe.waitUntilFinished("old")
        await Task.yield()

        #expect(await probe.wasCancelled("old"))
        #expect(!(await probe.wasCancelled("new")))

        registry.cancel(hostID: "host")
        await probe.waitUntilCancelled("new")
        #expect(await probe.wasCancelled("new"))
    }

    @Test("deselect cancellation affects only that host")
    func cancelRemovesOneHostTask() async {
        let registry = SnippetCompatibilityTaskRegistry()
        let probe = CompatibilityTaskProbe()

        registry.replace(hostID: "host-a") { _ in
            await probe.run("host-a")
        }
        registry.replace(hostID: "host-b") { _ in
            await probe.run("host-b")
        }
        await probe.waitUntilStarted("host-a")
        await probe.waitUntilStarted("host-b")

        registry.cancel(hostID: "host-a")
        await probe.waitUntilCancelled("host-a")

        #expect(await probe.wasCancelled("host-a"))
        #expect(!(await probe.wasCancelled("host-b")))

        registry.cancel(hostID: "host-b")
        await probe.waitUntilCancelled("host-b")
    }

    @Test("cancelAll cancels every host task")
    func cancelAllCancelsEveryTask() async {
        let registry = SnippetCompatibilityTaskRegistry()
        let probe = CompatibilityTaskProbe()

        for hostID in ["host-a", "host-b"] {
            registry.replace(hostID: hostID) { _ in
                await probe.run(hostID)
            }
            await probe.waitUntilStarted(hostID)
        }

        registry.cancelAll()
        await probe.waitUntilCancelled("host-a")
        await probe.waitUntilCancelled("host-b")

        #expect(await probe.wasCancelled("host-a"))
        #expect(await probe.wasCancelled("host-b"))
    }

    @Test("cancelAll suppresses a late result from an operation that ignores cancellation")
    func cancelAllRejectsLatePublication() async {
        let registry = SnippetCompatibilityTaskRegistry()
        let operation = CancellationIgnoringOperation(value: "late-value")
        var publishedValues: [String] = []
        var publishedErrors: [String] = []

        registry.replace(hostID: "host") { claim in
            let value = await operation.waitForRelease()
            if let accepted = registry.accept(value, for: claim) {
                publishedValues.append(accepted.value)
            }
            if let accepted = registry.accept("late-error", for: claim) {
                publishedErrors.append(accepted.value)
            }
            await operation.markFinished()
        }
        await operation.waitUntilStarted()

        registry.cancelAll()
        await operation.release()
        await operation.waitUntilFinished()

        #expect(publishedValues.isEmpty)
        #expect(publishedErrors.isEmpty)
    }

    @Test("replacement suppresses the old late result and accepts the new owner")
    func replacementRejectsOldPublication() async {
        let registry = SnippetCompatibilityTaskRegistry()
        let oldOperation = CancellationIgnoringOperation(value: "old-value")
        let replacementFinished = AsyncTestSignal()
        var published: [String] = []

        registry.replace(hostID: "host") { claim in
            let value = await oldOperation.waitForRelease()
            if let accepted = registry.accept(value, for: claim) {
                published.append(accepted.value)
            }
            await oldOperation.markFinished()
        }
        await oldOperation.waitUntilStarted()

        registry.replace(hostID: "host") { claim in
            if let accepted = registry.accept("new-value", for: claim) {
                published.append(accepted.value)
            }
            await replacementFinished.fire()
        }
        await replacementFinished.wait()
        await oldOperation.release()
        await oldOperation.waitUntilFinished()

        #expect(published == ["new-value"])
    }
}

private actor CancellationIgnoringOperation {
    private let value: String
    private var releaseContinuation: CheckedContinuation<String, Never>?
    private var started = false
    private var finished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(value: String) {
        self.value = value
    }

    func waitForRelease() async -> String {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume(returning: value)
        releaseContinuation = nil
    }

    func markFinished() {
        finished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }
}

private actor AsyncTestSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        fired = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor CompatibilityTaskProbe {
    private var started: Set<String> = []
    private var cancelled: Set<String> = []
    private var finished: Set<String> = []
    private var operationWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var finishWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func run(_ id: String) async {
        started.insert(id)
        resume(&startWaiters, for: id)

        await withTaskCancellationHandler {
            await suspendUntilCancelled(id)
        } onCancel: {
            Task { await self.recordCancellation(id) }
        }

        finished.insert(id)
        resume(&finishWaiters, for: id)
    }

    func waitUntilStarted(_ id: String) async {
        if started.contains(id) { return }
        await withCheckedContinuation { continuation in
            startWaiters[id, default: []].append(continuation)
        }
    }

    func waitUntilCancelled(_ id: String) async {
        if cancelled.contains(id) { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[id, default: []].append(continuation)
        }
    }

    func waitUntilFinished(_ id: String) async {
        if finished.contains(id) { return }
        await withCheckedContinuation { continuation in
            finishWaiters[id, default: []].append(continuation)
        }
    }

    func wasCancelled(_ id: String) -> Bool {
        cancelled.contains(id)
    }

    private func suspendUntilCancelled(_ id: String) async {
        if cancelled.contains(id) { return }
        await withCheckedContinuation { continuation in
            operationWaiters[id] = continuation
        }
    }

    private func recordCancellation(_ id: String) {
        cancelled.insert(id)
        operationWaiters.removeValue(forKey: id)?.resume()
        resume(&cancellationWaiters, for: id)
    }

    private func resume(
        _ waiters: inout [String: [CheckedContinuation<Void, Never>]],
        for id: String
    ) {
        let continuations = waiters.removeValue(forKey: id) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }
}
