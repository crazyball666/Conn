import Foundation

/// 历史输出重放给终端模拟器时，阻止模拟器把查询响应再次写回当前 PTY。
///
/// 计数而不是单一 Bool：UIView 在旧渲染任务完成取消前可能立即重新 attach；
/// 只有所有已开始的回放都结束后，新的实时输入才会重新放行。
final class TerminalReplayOutboundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var replayDepth = 0

    var allowsTerminalDelegateOutput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return replayDepth == 0
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
}
