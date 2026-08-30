import ConnSSH
import Foundation

package let zellijTerminalEnvironmentBootstrap = """
if [ -z "${TERM:-}" ]; then
    TERM=xterm-256color
    export TERM
fi
"""

package func zellijAttachmentScript(
    executable: String,
    sessionName: ZellijSessionName,
    nonce: String
) -> String {
    let executable = POSIXShellArgument.encode(executable)
    let sessionName = POSIXShellArgument.encode(sessionName.rawValue)
    let nonce = POSIXShellArgument.encode(nonce)
    return """
    zellij_path=\(executable)
    session_name=\(sessionName)
    nonce=\(nonce)
    \(zellijTerminalEnvironmentBootstrap)
    if ! sessions=$("$zellij_path" list-sessions --short --no-formatting 2>/dev/null); then
        printf '__CONN_ZELLIJ_UNAVAILABLE_v1__ nonce=%s\n' "$nonce"
        exit 70
    fi
    if ! printf '%s\n' "$sessions" | grep -Fqx -- "$session_name"; then
        printf '__CONN_ZELLIJ_MISSING_v1__ nonce=%s\n' "$nonce"
        exit 75
    fi
    printf '__CONN_ZELLIJ_ATTACH_v1__ nonce=%s\n' "$nonce"
    exec "$zellij_path" attach "$session_name"
    """
}

package final class ZellijPassthroughAttachment:
    PersistentTerminalInteractiveAttachment,
    @unchecked Sendable {
    package let descriptor: PersistentAttachmentDescriptor
    package let presentation: PersistentAttachmentPresentation
    package let attachmentGeneration: UInt64
    package let lifecycleEvents: AsyncStream<PersistentTerminalAttachmentLifecycleEvent>
    package var interaction: any PersistentTerminalInteractionFacet {
        interactionFacet
    }

    private let channel: ZellijProcessShellChannel
    private let interactionFacet: ZellijInteractionFacet
    private let lifecycleContinuation:
        AsyncStream<PersistentTerminalAttachmentLifecycleEvent>.Continuation
    private let lock = NSLock()
    private var didClose = false
    private var lifecycleTask: Task<Void, Never>?

    package init(
        descriptor: PersistentAttachmentDescriptor,
        channel: ZellijProcessShellChannel,
        actionExecutor: any ZellijActionCommandExecuting,
        attachmentGeneration: UInt64,
        processExitTimeout: Duration = .seconds(3)
    ) {
        self.descriptor = descriptor
        self.channel = channel
        self.attachmentGeneration = attachmentGeneration
        (lifecycleEvents, lifecycleContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        interactionFacet = ZellijInteractionFacet(
            descriptor: descriptor,
            channel: channel,
            actionExecutor: actionExecutor,
            attachmentGeneration: attachmentGeneration,
            processExitTimeout: processExitTimeout
        )
        presentation = .byteTerminal(channel)
        lifecycleTask = Task { [weak self] in
            await self?.observeProcessExit()
        }
    }

    package func close() async {
        guard lock.withLock({
            guard !didClose else { return false }
            didClose = true
            return true
        }) else { return }
        let lifecycleTask = lifecycleTask
        self.lifecycleTask = nil
        await interactionFacet.close()
        await channel.close()
        if let lifecycleTask {
            await lifecycleTask.value
        }
        lifecycleContinuation.finish()
    }

    private func observeProcessExit() async {
        let event: PersistentTerminalAttachmentLifecycleEvent
        do {
            let exit = try await channel.waitForProcessExit()
            if exit.exitCode == 0, exit.signal == nil {
                event = .workspaceClosed
            } else {
                event = .failed(.init(
                    componentID: "zellij.attach-process",
                    issue: .transportClosed,
                    recovery: .rebuildAttachment
                ))
            }
        } catch {
            event = .failed(.init(
                componentID: "zellij.attach-process",
                issue: .transportClosed,
                recovery: .rebuildAttachment
            ))
        }
        guard lock.withLock({ !didClose }) else { return }
        lifecycleContinuation.yield(event)
        lifecycleContinuation.finish()
    }
}

package final class ZellijProcessShellChannel: ShellChannel, @unchecked Sendable {
    package let output: AsyncThrowingStream<Data, Error>

    private let process: any RemoteProcessChannel
    private let nonce: String
    private let readiness = ZellijAttachmentReadinessGate()
    private let writer: ZellijProcessWriter
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var preamble = Data()
    private var scanOffset = 0
    private var didResolveReadiness = false
    private var didClose = false
    private var pumpTask: Task<Void, Never>?

    private init(process: any RemoteProcessChannel, nonce: String) {
        self.process = process
        self.nonce = nonce
        writer = ZellijProcessWriter(process: process)
        (output, continuation) = AsyncThrowingStream.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.close() }
        }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    package static func open(
        process: any RemoteProcessChannel,
        nonce: String,
        readinessTimeout: Duration = .seconds(2)
    ) async throws -> ZellijProcessShellChannel {
        let channel = ZellijProcessShellChannel(process: process, nonce: nonce)
        do {
            try await channel.waitForReadiness(timeout: readinessTimeout)
            return channel
        } catch {
            await channel.close()
            throw error
        }
    }

    package func write(_ bytes: Data) async throws {
        try await writer.write(bytes)
    }

    package func resize(_ size: TermSize) async throws {
        try await writer.resize(size)
    }

    package func close() async {
        guard lock.withLock({
            guard !didClose else { return false }
            didClose = true
            return true
        }) else { return }
        await readiness.fail(PersistentTerminalError.transportClosed)
        await writer.close()
        pumpTask?.cancel()
        if let pumpTask {
            await pumpTask.value
        }
        continuation.finish()
    }

    package func waitForProcessExit() async throws -> RemoteProcessExit {
        try await process.result()
    }

    private func waitForReadiness(timeout: Duration) async throws {
        let race = ZellijAttachmentReadinessRace()
        let readinessTask = Task { [readiness] in
            do {
                try await readiness.wait()
                await race.resolve(.ready)
            } catch let error as PersistentTerminalError {
                await race.resolve(.failure(error))
            } catch {
                await race.resolve(.failure(.protocolViolation))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                await race.resolve(.failure(.protocolViolation))
            } catch {
                // The readiness result won the race.
            }
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            readinessTask.cancel()
            timeoutTask.cancel()
            Task { await race.resolve(.failure(.transportClosed)) }
        }
        readinessTask.cancel()
        timeoutTask.cancel()

        switch outcome {
        case .ready:
            return
        case let .failure(error):
            throw error
        }
    }

    private func pump() async {
        do {
            for try await event in process.output {
                guard !Task.isCancelled else { return }
                switch event {
                case let .stdout(data), let .stderr(data):
                    await consume(data)
                }
            }
            let unresolved = lock.withLock { !didResolveReadiness }
            if unresolved {
                await readiness.fail(PersistentTerminalError.protocolViolation)
                continuation.finish(throwing: PersistentTerminalError.protocolViolation)
            } else {
                continuation.finish()
            }
        } catch {
            await readiness.fail(error)
            continuation.finish(throwing: error)
        }
    }

    private func consume(_ data: Data) async {
        if lock.withLock({ didResolveReadiness }) {
            continuation.yield(data)
            return
        }

        let consumed: (ZellijAttachmentReadiness?, Data, Bool) = lock.withLock {
            if didResolveReadiness {
                return (nil, data, true)
            }
            preamble.append(data)
            var forwarded = Data()
            var outcome: ZellijAttachmentReadiness?
            if preamble.count > 4 * 1024 {
                outcome = .failure(.protocolViolation)
            } else {
                while scanOffset < preamble.count,
                      let newline = preamble[scanOffset...].firstIndex(of: UInt8(ascii: "\n")) {
                    var line = Data(preamble[scanOffset ..< newline])
                    scanOffset = newline + 1
                    if line.last == UInt8(ascii: "\r") {
                        line.removeLast()
                    }
                    let text = String(decoding: line, as: UTF8.self)
                    if text == "__CONN_ZELLIJ_ATTACH_v1__ nonce=\(nonce)" {
                        didResolveReadiness = true
                        outcome = .ready
                    } else if text == "__CONN_ZELLIJ_MISSING_v1__ nonce=\(nonce)" {
                        outcome = .failure(.remoteObjectMissing)
                    } else if text == "__CONN_ZELLIJ_UNAVAILABLE_v1__ nonce=\(nonce)" {
                        outcome = .failure(.serverUnavailable)
                    }
                    if outcome != nil {
                        let remainder = newline + 1
                        if remainder < preamble.count {
                            forwarded = Data(preamble[remainder...])
                        }
                        preamble.removeAll(keepingCapacity: true)
                        scanOffset = 0
                        break
                    }
                }
            }
            return (outcome, forwarded, false)
        }
        let (outcome, forwarded, wasAlreadyReady) = consumed

        if wasAlreadyReady {
            continuation.yield(forwarded)
            return
        }

        switch outcome {
        case .ready:
            await readiness.ready()
            if !forwarded.isEmpty {
                continuation.yield(forwarded)
            }
        case let .failure(error):
            await readiness.fail(error)
            continuation.finish(throwing: error)
        case nil:
            break
        }
    }
}

private enum ZellijAttachmentReadiness {
    case ready
    case failure(PersistentTerminalError)
}

private actor ZellijAttachmentReadinessRace {
    private enum State {
        case pending([CheckedContinuation<ZellijAttachmentReadiness, Never>])
        case resolved(ZellijAttachmentReadiness)
    }

    private var state: State = .pending([])

    func wait() async -> ZellijAttachmentReadiness {
        switch state {
        case let .resolved(outcome):
            outcome
        case .pending:
            await withCheckedContinuation { continuation in
                guard case var .pending(waiters) = state else { return }
                waiters.append(continuation)
                state = .pending(waiters)
            }
        }
    }

    func resolve(_ outcome: ZellijAttachmentReadiness) {
        guard case let .pending(waiters) = state else { return }
        state = .resolved(outcome)
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }
}

private actor ZellijAttachmentReadinessGate {
    private enum State {
        case pending([CheckedContinuation<Void, any Error>])
        case ready
        case failed(any Error)
    }

    private var state: State = .pending([])

    func wait() async throws {
        switch state {
        case .ready:
            return
        case let .failed(error):
            throw error
        case .pending:
            try await withCheckedThrowingContinuation { continuation in
                guard case var .pending(waiters) = state else { return }
                waiters.append(continuation)
                state = .pending(waiters)
            }
        }
    }

    func ready() {
        guard case let .pending(waiters) = state else { return }
        state = .ready
        for waiter in waiters {
            waiter.resume()
        }
    }

    func fail(_ error: any Error) {
        guard case let .pending(waiters) = state else { return }
        state = .failed(error)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}

package actor ZellijProcessWriter {
    private let process: any RemoteProcessChannel
    private var isClosed = false
    private var pendingOperation: Task<Void, any Error>?

    package init(process: any RemoteProcessChannel) {
        self.process = process
    }

    package func write(_ bytes: Data) async throws {
        try await enqueue { [process] in
            try await process.write(bytes)
        }
    }

    package func resize(_ size: TermSize) async throws {
        try await enqueue { [process] in
            try await process.resize(size)
        }
    }

    package func close() async {
        guard !isClosed else { return }
        isClosed = true
        await process.close()
        if let pendingOperation {
            _ = await pendingOperation.result
        }
    }

    private func enqueue(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard !isClosed else { throw PersistentTerminalError.transportClosed }
        let previous = pendingOperation
        let task = Task {
            if let previous {
                try await previous.value
            }
            try await operation()
        }
        pendingOperation = task
        try await task.value
    }
}
