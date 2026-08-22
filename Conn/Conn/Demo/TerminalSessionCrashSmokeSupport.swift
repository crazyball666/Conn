#if DEBUG
import ConnSSH
import Foundation

/// UI 回归测试专用的空终端通道，用于在不依赖网络的情况下保留一个活动 Tab，
/// 覆盖“已有终端时新增主机”的真实崩溃路径。Release 不会编译此类型。
final class TerminalSessionCrashSmokeChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func write(_ bytes: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func close() async { continuation.finish() }
}
#endif
