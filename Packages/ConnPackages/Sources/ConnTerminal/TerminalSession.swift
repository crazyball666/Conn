import ConnSSH
import Foundation

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
    private let frameInterval: UInt64
    private let lifecycleContinuation: AsyncStream<TerminalSessionLifecycleEvent>.Continuation

    public nonisolated let lifecycleEvents: AsyncStream<TerminalSessionLifecycleEvent>

    private var pumpTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var legacyFeedTask: Task<Void, Never>?
    private var pending: [UInt8] = []
    private var hasPublishedLifecycle = false
    public private(set) var state: State = .idle

    public init(
        channel: any ShellChannel,
        transcript: TerminalTranscript,
        generation: UInt64,
        frameIntervalMillis: UInt64 = 16
    ) {
        self.channel = channel
        self.transcript = transcript
        self.generation = generation
        frameInterval = frameIntervalMillis * 1_000_000
        let stream = AsyncStream<TerminalSessionLifecycleEvent>.makeStream(bufferingPolicy: .unbounded)
        lifecycleEvents = stream.stream
        lifecycleContinuation = stream.continuation
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
                    await self.enqueue([UInt8](chunk))
                }
                await self.finishClosed()
            } catch is CancellationError {
                await self.finishClosed()
            } catch {
                await self.finishFailed(message: String(describing: error))
            }
        }
    }

    /// 临时保留给仍在迁移中的老页面。新 UI 应直接 attach `TerminalTranscript`。
    public func start(onFeed: @escaping @Sendable ([UInt8]) -> Void) {
        start()
        guard legacyFeedTask == nil else { return }
        legacyFeedTask = Task { [weak self] in
            guard let self else { return }
            let attachment = await self.transcript.attach()
            for await event in attachment.events {
                switch event {
                case let .replayBytes(bytes), let .liveBytes(bytes):
                    onFeed(bytes)
                case .generationBoundary:
                    onFeed(TerminalTranscript.generationBoundaryBytes)
                case .replayStarted, .replayFinished:
                    break
                }
            }
        }
    }

    /// 用户输入 → PTY。写入失败必须让上层把已存在的 tab 标成断开。
    public func send(_ bytes: [UInt8]) async throws {
        do {
            try await channel.write(Data(bytes))
        } catch {
            await finishFailed(message: String(describing: error))
            throw error
        }
    }

    /// 终端尺寸变化 → PTY resize（SIGWINCH）。
    public func resize(cols: Int, rows: Int) async throws {
        do {
            try await channel.resize(TermSize(cols: cols, rows: rows))
        } catch {
            await finishFailed(message: String(describing: error))
            throw error
        }
    }

    /// 只关闭当前 PTY；绝不触碰承载它的共享 SSH 连接。
    public func close() async {
        guard state != .closed else { return }
        await channel.close()
        flushTask?.cancel()
        flushTask = nil
        await flush()
        pumpTask?.cancel()
        if let pumpTask {
            await pumpTask.value
        }
        legacyFeedTask?.cancel()
        legacyFeedTask = nil
        await finishClosed()
    }

    private func enqueue(_ bytes: [UInt8]) {
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

    private func finishClosed() async {
        guard !hasPublishedLifecycle else { return }
        await flush()
        hasPublishedLifecycle = true
        state = .closed
        lifecycleContinuation.yield(.closed)
        lifecycleContinuation.finish()
    }

    private func finishFailed(message: String?) async {
        guard !hasPublishedLifecycle else { return }
        await flush()
        hasPublishedLifecycle = true
        state = .failed
        lifecycleContinuation.yield(.failed(message: message))
        lifecycleContinuation.finish()
    }
}
