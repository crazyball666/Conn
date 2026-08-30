import ConnUI
import Foundation

/// 终端视口在页面销毁与重新打开之间保留的轻量状态。
public struct TerminalViewportState: Sendable, Equatable {
    public var followsLiveOutput: Bool
    public var scrollPosition: Double

    public init(followsLiveOutput: Bool = true, scrollPosition: Double = 1) {
        self.followsLiveOutput = followsLiveOutput
        self.scrollPosition = scrollPosition
    }

    public static let `default` = TerminalViewportState()
}

/// 单次 UI 绑定：回放和实时帧共享同一个有序 stream。
public struct TerminalAttachment: Sendable {
    public let id: UUID
    public let events: TerminalRenderEventStream

    fileprivate init(id: UUID, events: TerminalRenderEventStream) {
        self.id = id
        self.events = events
    }
}

public enum TerminalRenderEvent: Sendable, Equatable {
    case replayStarted(requiresReset: Bool)
    case replayBytes([UInt8])
    case replayFinished(TerminalViewportState)
    case generationBoundary
    case liveBytes([UInt8])
}

public enum TerminalTranscriptReplayPolicy: Sendable, Equatable {
    case buffered
    case authoritativeRemote
}

/// A lossless single-consumer stream backed by a coalescing mailbox. Adjacent live byte
/// frames are merged while rendering is busy, avoiding one retained allocation per PTY frame.
public struct TerminalRenderEventStream: AsyncSequence, Sendable {
    public typealias Element = TerminalRenderEvent

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let mailbox: TerminalRenderMailbox

        public mutating func next() async -> TerminalRenderEvent? {
            await mailbox.next()
        }
    }

    fileprivate let mailbox: TerminalRenderMailbox

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mailbox: mailbox)
    }
}

private final class TerminalRenderMailbox: @unchecked Sendable {
    private final class LiveBytesBuffer {
        var bytes: [UInt8]

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }
    }

    private enum QueuedEvent {
        case event(TerminalRenderEvent)
        case liveBytes(LiveBytesBuffer)

        init(_ event: TerminalRenderEvent) {
            if case let .liveBytes(bytes) = event {
                self = .liveBytes(LiveBytesBuffer(bytes))
            } else {
                self = .event(event)
            }
        }

        var renderEvent: TerminalRenderEvent {
            switch self {
            case let .event(event):
                event
            case let .liveBytes(buffer):
                .liveBytes(buffer.bytes)
            }
        }

        var liveByteCount: Int {
            if case let .liveBytes(buffer) = self {
                return buffer.bytes.count
            }
            return 0
        }
    }

    private let maxPendingLiveBytes: Int
    private let lock = NSLock()
    private var pending: [QueuedEvent] = []
    private var head = 0
    private var pendingLiveBytes = 0
    private var waiter: CheckedContinuation<TerminalRenderEvent?, Never>?
    private var finished = false

    init(maxPendingLiveBytes: Int) {
        self.maxPendingLiveBytes = max(maxPendingLiveBytes, 1)
    }

    /// Returns false when the live backlog reached its byte budget. The transcript then
    /// replaces pending frames with one bounded replay snapshot, preserving terminal state
    /// without dropping arbitrary ANSI bytes.
    func enqueue(_ event: TerminalRenderEvent) -> Bool {
        var resumedWaiter: CheckedContinuation<TerminalRenderEvent?, Never>?
        let accepted = lock.withLock { () -> Bool in
            guard !finished else { return true }
            if let currentWaiter = waiter {
                waiter = nil
                resumedWaiter = currentWaiter
                return true
            }

            if case let .liveBytes(bytes) = event {
                guard pendingLiveBytes + bytes.count <= maxPendingLiveBytes else {
                    return false
                }
                pendingLiveBytes += bytes.count
                if head < pending.count,
                   case let .liveBytes(buffer) = pending[pending.count - 1]
                {
                    buffer.bytes.append(contentsOf: bytes)
                } else {
                    pending.append(.liveBytes(LiveBytesBuffer(bytes)))
                }
            } else {
                pending.append(.event(event))
            }
            return true
        }
        resumedWaiter?.resume(returning: event)
        return accepted
    }

    func replacePending(with events: [TerminalRenderEvent]) {
        var resumedWaiter: CheckedContinuation<TerminalRenderEvent?, Never>?
        var firstEvent: TerminalRenderEvent?
        lock.withLock {
            guard !finished else { return }
            pending.removeAll(keepingCapacity: true)
            head = 0
            pendingLiveBytes = 0
            if let currentWaiter = waiter, let first = events.first {
                waiter = nil
                resumedWaiter = currentWaiter
                firstEvent = first
                pending.append(contentsOf: events.dropFirst().map(QueuedEvent.init))
            } else {
                pending.append(contentsOf: events.map(QueuedEvent.init))
            }
            pendingLiveBytes = pending.reduce(into: 0) { count, event in
                count += event.liveByteCount
            }
        }
        if let resumedWaiter {
            resumedWaiter.resume(returning: firstEvent)
        }
    }

    func next() async -> TerminalRenderEvent? {
        await withCheckedContinuation { continuation in
            var shouldResume = false
            var result: TerminalRenderEvent?
            lock.withLock {
                if head < pending.count {
                    let queuedEvent = pending[head]
                    result = queuedEvent.renderEvent
                    head += 1
                    pendingLiveBytes -= queuedEvent.liveByteCount
                    compactIfNeeded()
                    shouldResume = true
                } else if finished {
                    shouldResume = true
                } else {
                    precondition(waiter == nil, "Terminal render stream supports one consumer")
                    waiter = continuation
                }
            }
            if shouldResume {
                continuation.resume(returning: result)
            }
        }
    }

    func finish() {
        var resumedWaiter: CheckedContinuation<TerminalRenderEvent?, Never>?
        lock.withLock {
            guard !finished else { return }
            finished = true
            if head >= pending.count {
                resumedWaiter = waiter
                waiter = nil
            }
        }
        resumedWaiter?.resume(returning: nil)
    }

    private func compactIfNeeded() {
        guard head >= 64, head >= pending.count / 2 else { return }
        pending.removeSubrange(..<head)
        head = 0
    }
}

/// 跨终端页面和 PTY generation 保留的输出与视口。
public actor TerminalTranscript {
    /// 只做软复位，不使用会清空 scrollback 的 RIS（ESC c）。
    public static var generationBoundaryBytes: [UInt8] {
        Array(
            "\u{1B}[?1049l\u{1B}[!p\u{1B}[0m\u{1B}[?25h\u{1B}[?7h\r\n\r\n[\(L("已重新连接"))]\r\n".utf8
        )
    }

    private var replayBuffer: TerminalReplayBuffer
    private let maxPendingLiveBytes: Int
    private var activeGeneration: UInt64?
    private var viewport = TerminalViewportState.default
    private var attachment: ActiveAttachment?

    public init(
        maxLines: Int = 10000,
        maxBytes: Int = 4 * 1024 * 1024,
        maxPendingLiveBytes: Int = 512 * 1024
    ) {
        replayBuffer = TerminalReplayBuffer(maxLines: maxLines, maxBytes: maxBytes)
        self.maxPendingLiveBytes = max(maxPendingLiveBytes, 1)
    }

    public func activateGeneration(_ generation: UInt64) {
        activeGeneration = generation
    }

    public func append(_ bytes: [UInt8], generation: UInt64) {
        guard activeGeneration == generation, !bytes.isEmpty else { return }
        replayBuffer.append(bytes)
        guard let attachment else { return }
        if !attachment.mailbox.enqueue(.liveBytes(bytes)) {
            resynchronize(attachment.mailbox)
        }
    }

    public func appendGenerationBoundary(_ generation: UInt64) {
        guard activeGeneration == generation else { return }
        replayBuffer.append(Self.generationBoundaryBytes)
        _ = attachment?.mailbox.enqueue(.generationBoundary)
    }

    public func attach(
        replayPolicy: TerminalTranscriptReplayPolicy = .buffered
    ) -> TerminalAttachment {
        let mailbox = TerminalRenderMailbox(maxPendingLiveBytes: maxPendingLiveBytes)
        let id = UUID()
        attachment?.mailbox.finish()
        attachment = ActiveAttachment(id: id, mailbox: mailbox, replayPolicy: replayPolicy)

        let initialEvents: [TerminalRenderEvent]
        switch replayPolicy {
        case .buffered:
            let snapshot = replayBuffer.snapshot
            var events: [TerminalRenderEvent] = [
                .replayStarted(requiresReset: snapshot.wasTruncated),
            ]
            if !snapshot.bytes.isEmpty {
                events.append(.replayBytes(snapshot.bytes))
            }
            events.append(.replayFinished(viewport))
            initialEvents = events
        case .authoritativeRemote:
            initialEvents = [
                .replayStarted(requiresReset: true),
                .replayFinished(.default),
            ]
        }
        mailbox.replacePending(with: initialEvents)

        return TerminalAttachment(id: id, events: TerminalRenderEventStream(mailbox: mailbox))
    }

    public func detach(_ attachmentID: UUID) {
        guard attachment?.id == attachmentID else { return }
        attachment?.mailbox.finish()
        attachment = nil
    }

    public func updateViewport(_ state: TerminalViewportState) {
        viewport = state
    }

    private struct ActiveAttachment {
        let id: UUID
        let mailbox: TerminalRenderMailbox
        let replayPolicy: TerminalTranscriptReplayPolicy
    }

    private func resynchronize(_ mailbox: TerminalRenderMailbox) {
        if attachment?.mailbox === mailbox,
           attachment?.replayPolicy == .authoritativeRemote {
            mailbox.replacePending(with: [
                .replayStarted(requiresReset: true),
                .replayFinished(.default),
            ])
            return
        }
        let snapshot = replayBuffer.snapshot
        var events: [TerminalRenderEvent] = [.replayStarted(requiresReset: true)]
        if !snapshot.bytes.isEmpty {
            events.append(.replayBytes(snapshot.bytes))
        }
        events.append(.replayFinished(viewport))
        mailbox.replacePending(with: events)
    }
}
