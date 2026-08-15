import Foundation

enum TerminalFeedProvenance: Sendable, Equatable {
    case outsideFeed
    case replay
    case generationBoundary
    case live(generation: UInt64)
}

/// 历史输出重放给终端模拟器时，阻止模拟器把查询响应再次写回当前 PTY。
///
/// 计数而不是单一 Bool：UIView 在旧渲染任务完成取消前可能立即重新 attach；
/// 只有所有已开始的回放都结束后，新的实时输入才会重新放行。
final class TerminalReplayOutboundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var replayDepth = 0
    private var feedProvenance: TerminalFeedProvenance = .outsideFeed

    var allowsTerminalDelegateOutput: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard replayDepth == 0 else { return false }
        return switch feedProvenance {
        case .replay, .generationBoundary: false
        case .outsideFeed, .live: true
        }
    }

    var allowsHostSideEffects: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard replayDepth == 0 else { return false }
        if case .live = feedProvenance { return true }
        return false
    }

    var currentFeedProvenance: TerminalFeedProvenance {
        lock.lock()
        defer { lock.unlock() }
        return feedProvenance
    }

    func beginReplay() {
        lock.lock()
        replayDepth += 1
        lock.unlock()
    }

    func finishReplay() {
        lock.lock()
        replayDepth = max(0, replayDepth - 1)
        lock.unlock()
    }

    @discardableResult
    func withFeed<Result>(
        _ provenance: TerminalFeedProvenance,
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        let previous = feedProvenance
        feedProvenance = provenance
        lock.unlock()
        defer {
            lock.lock()
            feedProvenance = previous
            lock.unlock()
        }
        return try body()
    }
}
