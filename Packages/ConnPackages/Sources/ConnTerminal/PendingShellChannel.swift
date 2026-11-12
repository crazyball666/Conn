import ConnSSH
import Foundation

/// 本地 Tab 先出现、远端通道后建立时使用的占位通道。
///
/// 它不产生输出，也不把输入发往任何地方；连接成功后协调器会用真实
/// `ShellChannel` 替换整个 `TerminalSession`，因此占位通道永远不会成为业务通道。
final class PendingShellChannel: ShellChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var closed = false

    let output: AsyncThrowingStream<Data, any Error>

    init() {
        var captured: AsyncThrowingStream<Data, any Error>.Continuation?
        output = AsyncThrowingStream { continuation in
            captured = continuation
        }
        continuation = captured
    }

    func write(_ bytes: Data) async throws {
        // Input is intentionally ignored until the real PTY is attached.
    }

    func resize(_ size: TermSize) async throws {
        // The real PTY is resized after the connection succeeds.
    }

    func close() async {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldFinish else { return }
        continuation?.finish()
        continuation = nil
    }
}
