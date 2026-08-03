import Citadel
import ConnSSH
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// Citadel `withPTY` 支撑的交互式 shell 通道。
///
/// `withPTY` 的 PTY 只在闭包期间存活。通道以一个长驻 task 持有闭包，并由
/// `ShellChannelLifecycleGate` 串行化 writer 就绪、远端 EOF、错误和本地关闭，保证
/// open continuation 与输出流均只结束一次。
final class CitadelShellChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private let writerBox = NIOLockedValueBox<TTYStdinWriter?>(nil)
    private let completionBox = NIOLockedValueBox(false)
    private let lifecycle = ShellChannelLifecycleGate()
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

        channel.ptyTask = Task {
            await channel.run(client: client, request: request)
        }
        try await channel.lifecycle.waitForReady()
        return channel
    }

    private func run(client: SSHClient, request: SSHChannelRequestEvent.PseudoTerminalRequest) async {
        do {
            try await client.withPTY(request) { inbound, outbound in
                writerBox.withLockedValue { $0 = outbound }
                lifecycle.markReady()

                if let error = await pump(inbound) {
                    finish(error: error)
                } else {
                    // 远端正常 EOF 也意味着 PTY 已结束，不能继续等待用户本地 close。
                    finish(error: nil)
                }

                // `finish` 已把 stop 标记为完成；此 await 让 withPTY 立即离开闭包。
                await lifecycle.waitForStop()
            }
            finish(error: nil)
        } catch {
            // writer 就绪前：让 open() 抛原始错误；writer 就绪后：只结束 output，
            // 不可重复 resume 已成功的 open continuation。
            finish(error: error)
        }
    }

    /// 返回 nil 表示远端正常 EOF；非 nil 表示 reader 传输错误。
    private func pump(_ inbound: TTYOutput) async -> Error? {
        do {
            for try await chunk in inbound {
                switch chunk {
                case let .stdout(buffer), let .stderr(buffer):
                    outputContinuation.yield(Data(buffer.readableBytesView))
                }
            }
            return nil
        } catch {
            return error
        }
    }

    func write(_ bytes: Data) async throws {
        guard lifecycle.isWritable,
              let writer = writerBox.withLockedValue({ $0 }) else {
            throw SSHError.channelClosed
        }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        do {
            try await writer.write(buffer)
        } catch {
            finish(error: error)
            throw error
        }
    }

    func resize(_ size: TermSize) async throws {
        guard lifecycle.isWritable,
              let writer = writerBox.withLockedValue({ $0 }) else {
            throw SSHError.channelClosed
        }
        do {
            try await writer.changeSize(cols: size.cols, rows: size.rows, pixelWidth: 0, pixelHeight: 0)
        } catch {
            finish(error: error)
            throw error
        }
    }

    /// 只关闭当前 PTY；绝不触碰承载它的共享 SSH client。
    func close() async {
        finish(error: nil)
        ptyTask?.cancel()
    }

    private func finish(error: Error?) {
        let shouldFinish = completionBox.withLockedValue { completed -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldFinish else { return }

        writerBox.withLockedValue { $0 = nil }
        if let error {
            lifecycle.markOpenFailed(error)
            outputContinuation.finish(throwing: error)
        } else {
            lifecycle.markOpenFailed(SSHError.channelClosed)
            outputContinuation.finish()
        }
        lifecycle.terminate()
    }
}
