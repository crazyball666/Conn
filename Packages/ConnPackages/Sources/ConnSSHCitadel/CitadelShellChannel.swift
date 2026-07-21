import Citadel
import ConnSSH
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// Citadel `withPTY` 支撑的交互式 shell 通道。
///
/// **难点**：Citadel 的 `withPTY(_:environment:perform:)` 是闭包作用域式——PTY
/// 随闭包返回而关闭。但终端会话要活到用户关闭页面。解法：在一个长驻 Task 里跑
/// `withPTY`，闭包内一直挂起消费 `TTYOutput`（把它桥接到 `output` 流），同时用
/// `CheckedContinuation` 把 `TTYStdinWriter` 取出来供外部 `write`/`resize`。
/// 闭包直到 `finishSignal` 被触发（`close()`）才返回，PTY 才关闭。
final class CitadelShellChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private let writerBox = NIOLockedValueBox<TTYStdinWriter?>(nil)
    private let closeContinuationBox = NIOLockedValueBox<CheckedContinuation<Void, Never>?>(nil)
    private var ptyTask: Task<Void, Never>?

    private init() {
        (output, outputContinuation) = AsyncThrowingStream.makeStream()
    }

    /// 在给定 client 上开一个 PTY 并返回就绪的通道。
    static func open(client: SSHClient, term: TermSize) async throws -> CitadelShellChannel {
        let channel = CitadelShellChannel()

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: term.cols,
            terminalRowHeight: term.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        // 等待 writer 就绪再返回，保证调用方拿到通道后能立即 write。
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            channel.ptyTask = Task {
                do {
                    try await client.withPTY(request) { inbound, outbound in
                        channel.writerBox.withLockedValue { $0 = outbound }
                        ready.resume()
                        // 桥接 PTY 输出到 output 流
                        await channel.pump(inbound)
                        // 挂起直到 close() 触发，否则闭包返回会立刻关闭 PTY
                        await withCheckedContinuation { (stop: CheckedContinuation<Void, Never>) in
                            channel.closeContinuationBox.withLockedValue { $0 = stop }
                        }
                    }
                    channel.outputContinuation.finish()
                } catch {
                    // withPTY 建立失败：若 ready 尚未 resume，让 open 抛错
                    channel.outputContinuation.finish(throwing: error)
                    channel.resumeCloseIfNeeded()
                    ready.resume(throwing: error)
                }
            }
        }
        return channel
    }

    private func pump(_ inbound: TTYOutput) async {
        do {
            for try await chunk in inbound {
                switch chunk {
                case let .stdout(buffer), let .stderr(buffer):
                    outputContinuation.yield(Data(buffer.readableBytesView))
                }
            }
        } catch {
            outputContinuation.finish(throwing: error)
        }
    }

    func write(_ bytes: Data) async throws {
        guard let writer = writerBox.withLockedValue({ $0 }) else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await writer.write(buffer)
    }

    func resize(_ size: TermSize) async throws {
        guard let writer = writerBox.withLockedValue({ $0 }) else { return }
        try await writer.changeSize(cols: size.cols, rows: size.rows, pixelWidth: 0, pixelHeight: 0)
    }

    func close() async {
        resumeCloseIfNeeded()
        outputContinuation.finish()
        ptyTask?.cancel()
    }

    /// 触发挂起的闭包返回（关闭 PTY）。幂等。
    private func resumeCloseIfNeeded() {
        let continuation = closeContinuationBox.withLockedValue { box -> CheckedContinuation<Void, Never>? in
            defer { box = nil }
            return box
        }
        continuation?.resume()
    }
}
