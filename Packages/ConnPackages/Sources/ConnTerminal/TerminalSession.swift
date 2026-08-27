import ConnSSH
import Foundation

private struct TerminalSessionUnavailableError: Error, Sendable {}

/// Thread-safe FIFO registered synchronously by terminal delegate callbacks. Only one write
/// reaches the transport at a time; the first failure atomically rejects the remaining queue.
private final class TerminalOutboundQueue: @unchecked Sendable {
    private struct Request {
        let id = UUID()
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>?
    }

    private let channel: any ShellChannel
    private let lock = NSLock()
    private var pending: [Request] = []
    private var head = 0
    private var draining = false
    private var terminalError: (any Error)?
    private var failureHandler: (@Sendable (any Error) -> Void)?

    init(channel: any ShellChannel) {
        self.channel = channel
    }

    func setFailureHandler(_ handler: @escaping @Sendable (any Error) -> Void) {
        lock.withLock { failureHandler = handler }
    }

    func enqueue(_ data: Data) {
        register(.init(data: data, continuation: nil))
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            register(.init(data: data, continuation: continuation))
        }
    }

    func terminate(with error: any Error) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard terminalError == nil else { return [] }
            terminalError = error
            draining = false
            let continuations = pending[head...].compactMap(\.continuation)
            pending.removeAll(keepingCapacity: false)
            head = 0
            return continuations
        }
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func register(_ request: Request) {
        var immediateError: (any Error)?
        let startsDrain = lock.withLock { () -> Bool in
            if let terminalError {
                immediateError = terminalError
                return false
            }
            pending.append(request)
            guard !draining else { return false }
            draining = true
            return true
        }
        if let immediateError {
            request.continuation?.resume(throwing: immediateError)
        } else if startsDrain {
            Task { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while let request = nextRequest() {
            do {
                try await channel.write(request.data)
            } catch {
                fail(with: error)
                return
            }
            complete(request)
        }
    }

    private func nextRequest() -> Request? {
        lock.withLock {
            guard terminalError == nil, head < pending.count else {
                draining = false
                return nil
            }
            return pending[head]
        }
    }

    private func complete(_ request: Request) {
        var continuation: CheckedContinuation<Void, any Error>?
        lock.withLock {
            guard terminalError == nil,
                  head < pending.count,
                  pending[head].id == request.id
            else { return }
            continuation = pending[head].continuation
            head += 1
            if head >= 64, head >= pending.count / 2 {
                pending.removeSubrange(..<head)
                head = 0
            }
        }
        continuation?.resume()
    }

    private func fail(with error: any Error) {
        var handler: (@Sendable (any Error) -> Void)?
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard terminalError == nil else { return [] }
            terminalError = error
            draining = false
            handler = failureHandler
            let continuations = pending[head...].compactMap(\.continuation)
            pending.removeAll(keepingCapacity: false)
            head = 0
            return continuations
        }
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        handler?(error)
    }
}

public enum TerminalSessionLifecycleEvent: Sendable, Equatable {
    case closed
    case failed(message: String?)
}

/// 一个 PTY generation 的输入输出桥接。
///
/// Session 不再属于任何 SwiftUI 页面：它把输出写入稳定的 transcript，页面可多次
/// attach/detach 而不影响 PTY 生命周期。
public actor TerminalSession {
    public enum State: Sendable, Equatable {
        case idle
        case running
        case closed
        case failed
    }

    private let channel: any ShellChannel
    private let transcript: TerminalTranscript
    private let generation: UInt64
    private nonisolated let outboundQueue: TerminalOutboundQueue
    private let frameInterval: UInt64
    private let resizeDebounceInterval: UInt64
    private let lifecycleContinuation: AsyncStream<TerminalSessionLifecycleEvent>.Continuation

    public nonisolated let lifecycleEvents: AsyncStream<TerminalSessionLifecycleEvent>

    private var pumpTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var pending: [UInt8] = []
    private var pendingResize: TermSize?
    private var lastDeliveredResize: TermSize?
    private var hasPublishedLifecycle = false
    public private(set) var state: State = .idle

    public init(
        channel: any ShellChannel,
        transcript: TerminalTranscript,
        generation: UInt64,
        frameIntervalMillis: UInt64 = 16,
        resizeDebounceMillis: UInt64 = 60
    ) {
        self.channel = channel
        self.transcript = transcript
        self.generation = generation
        outboundQueue = TerminalOutboundQueue(channel: channel)
        frameInterval = frameIntervalMillis * 1_000_000
        resizeDebounceInterval = resizeDebounceMillis * 1_000_000
        let stream = AsyncStream<TerminalSessionLifecycleEvent>.makeStream(bufferingPolicy: .unbounded)
        lifecycleEvents = stream.stream
        lifecycleContinuation = stream.continuation
        outboundQueue.setFailureHandler { [weak self] error in
            Task { await self?.finishFailed(error: error) }
        }
    }

    /// 过渡期兼容旧调用点；新代码必须显式传入 tab 的共享 transcript 与 generation。
    public init(channel: any ShellChannel, frameIntervalMillis: UInt64 = 16) {
        self.init(
            channel: channel,
            transcript: TerminalTranscript(),
            generation: 0,
            frameIntervalMillis: frameIntervalMillis
        )
    }

    /// 开始消费 PTY 输出。创建成功并加入全局 store 后才调用一次。
    public func start() {
        guard state == .idle else { return }
        state = .running
        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in self.channel.output {
                    await self.enqueueOutput([UInt8](chunk))
                }
                await self.finishClosed()
            } catch is CancellationError {
                await self.finishClosed()
            } catch {
                await self.finishFailed(error: error)
            }
        }
    }

    /// 用户输入 → PTY。写入失败必须让上层把已存在的 tab 标成断开。
    public nonisolated func send(_ bytes: [UInt8]) async throws {
        try await outboundQueue.send(Data(bytes))
    }

    /// UI delegate callbacks register bytes synchronously, preserving their source order
    /// without creating one unstructured Task per key or terminal protocol response.
    public nonisolated func enqueue(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        outboundQueue.enqueue(Data(bytes))
    }

    /// 终端尺寸变化 → PTY resize（SIGWINCH）。
    public func resize(cols: Int, rows: Int) async throws {
        let size = TermSize(cols: cols, rows: rows)
        guard size != pendingResize, size != lastDeliveredResize else { return }
        pendingResize = size
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.resizeDebounceInterval)
            } catch {
                return
            }
            await self.flushResize()
        }
    }

    /// 只关闭当前 PTY；绝不触碰承载它的共享 SSH 连接。
    public func close() async {
        guard state != .closed else { return }
        resizeTask?.cancel()
        resizeTask = nil
        pendingResize = nil
        outboundQueue.terminate(with: TerminalSessionUnavailableError())
        await channel.close()
        flushTask?.cancel()
        flushTask = nil
        await flush()
        pumpTask?.cancel()
        if let pumpTask {
            await pumpTask.value
        }
        await finishClosed()
    }

    private func enqueueOutput(_ bytes: [UInt8]) {
        pending.append(contentsOf: bytes)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.frameInterval)
            await self.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard !pending.isEmpty else { return }
        let frame = pending
        pending.removeAll(keepingCapacity: true)
        await transcript.append(frame, generation: generation)
    }

    private func flushResize() async {
        resizeTask = nil
        guard let size = pendingResize, size != lastDeliveredResize else {
            pendingResize = nil
            return
        }
        pendingResize = nil
        do {
            try await channel.resize(size)
            lastDeliveredResize = size
        } catch {
            await finishFailed(error: error)
        }
    }

    private func finishClosed() async {
        guard !hasPublishedLifecycle else { return }
        hasPublishedLifecycle = true
        state = .closed
        outboundQueue.terminate(with: TerminalSessionUnavailableError())
        resizeTask?.cancel()
        resizeTask = nil
        pendingResize = nil
        await flush()
        lifecycleContinuation.yield(.closed)
        lifecycleContinuation.finish()
    }

    private func finishFailed(error: any Error) async {
        guard !hasPublishedLifecycle else { return }
        hasPublishedLifecycle = true
        state = .failed
        outboundQueue.terminate(with: error)
        resizeTask?.cancel()
        resizeTask = nil
        pendingResize = nil
        await channel.close()
        await flush()
        lifecycleContinuation.yield(.failed(message: error.friendlyDiagnosis))
        lifecycleContinuation.finish()
    }
}
