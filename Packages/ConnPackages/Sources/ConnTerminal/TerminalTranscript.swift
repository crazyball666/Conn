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
    public let events: AsyncStream<TerminalRenderEvent>

    fileprivate init(id: UUID, events: AsyncStream<TerminalRenderEvent>) {
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

/// 跨终端页面和 PTY generation 保留的输出与视口。
public actor TerminalTranscript {
    /// 只做软复位，不使用会清空 scrollback 的 RIS（ESC c）。
    public static let generationBoundaryBytes = Array(
        "\u{1B}[?1049l\u{1B}[!p\u{1B}[0m\u{1B}[?25h\u{1B}[?7h\r\n\r\n[已重新连接]\r\n".utf8
    )

    private var replayBuffer: TerminalReplayBuffer
    private var activeGeneration: UInt64?
    private var viewport = TerminalViewportState.default
    private var attachment: ActiveAttachment?

    public init(maxLines: Int = 10_000, maxBytes: Int = 4 * 1024 * 1024) {
        replayBuffer = TerminalReplayBuffer(maxLines: maxLines, maxBytes: maxBytes)
    }

    public func activateGeneration(_ generation: UInt64) {
        activeGeneration = generation
    }

    public func append(_ bytes: [UInt8], generation: UInt64) {
        guard activeGeneration == generation, !bytes.isEmpty else { return }
        replayBuffer.append(bytes)
        attachment?.continuation.yield(.liveBytes(bytes))
    }

    public func appendGenerationBoundary(_ generation: UInt64) {
        guard activeGeneration == generation else { return }
        replayBuffer.append(Self.generationBoundaryBytes)
        attachment?.continuation.yield(.generationBoundary)
    }

    public func attach() -> TerminalAttachment {
        let stream = AsyncStream<TerminalRenderEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        attachment?.continuation.finish()
        attachment = ActiveAttachment(id: id, continuation: stream.continuation)

        let snapshot = replayBuffer.snapshot
        stream.continuation.yield(.replayStarted(requiresReset: snapshot.wasTruncated))
        if !snapshot.bytes.isEmpty {
            stream.continuation.yield(.replayBytes(snapshot.bytes))
        }
        stream.continuation.yield(.replayFinished(viewport))

        return TerminalAttachment(id: id, events: stream.stream)
    }

    public func detach(_ attachmentID: UUID) {
        guard attachment?.id == attachmentID else { return }
        attachment?.continuation.finish()
        attachment = nil
    }

    public func updateViewport(_ state: TerminalViewportState) {
        viewport = state
    }

    private struct ActiveAttachment {
        let id: UUID
        let continuation: AsyncStream<TerminalRenderEvent>.Continuation
    }
}
