import ConnSSH
import Foundation
import Testing
@testable import ConnTerminal

/// 可控测试通道：手动喂输出、记录写入。
private final class TestShellChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var written: [Data] = []
    private(set) var resizes: [TermSize] = []
    var writeError: Error?
    var resizeError: Error?
    private let lock = NSLock()

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
    func finish() { continuation.finish() }
    func fail(_ error: Error) { continuation.finish(throwing: error) }

    func write(_ bytes: Data) async throws {
        if let writeError { throw writeError }
        lock.withLock { written.append(bytes) }
    }

    func resize(_ size: TermSize) async throws {
        if let resizeError { throw resizeError }
        lock.withLock { resizes.append(size) }
    }

    func close() async { continuation.finish() }

    var writtenData: [Data] { lock.withLock { written } }
    var resizeSizes: [TermSize] { lock.withLock { resizes } }
}

private struct TestShellError: Error {}

@Suite("TerminalSession — transcript 与生命周期")
struct TerminalSessionTests {
    @Test("多次小块输出合帧写入 transcript")
    func batchesOutputIntoTranscript() async throws {
        let channel = TestShellChannel()
        let transcript = TerminalTranscript()
        await transcript.activateGeneration(1)
        let session = TerminalSession(
            channel: channel,
            transcript: transcript,
            generation: 1,
            frameIntervalMillis: 10
        )
        let attachment = await transcript.attach()
        var iterator = attachment.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        await session.start()

        // 快速连喂 5 个小块
        for index in 0 ..< 5 {
            channel.emit("chunk\(index)-")
        }
        // 等待超过一个合帧周期让 flush 触发
        try await Task.sleep(for: .milliseconds(60))

        #expect(await iterator.next() == .liveBytes(Array("chunk0-chunk1-chunk2-chunk3-chunk4-".utf8)))

        await session.close()
    }

    @Test("用户输入透传到通道")
    func forwardsInput() async throws {
        let channel = TestShellChannel()
        let transcript = TerminalTranscript()
        let session = TerminalSession(channel: channel, transcript: transcript, generation: 1)
        try await session.send([UInt8]("ls\n".utf8))
        try await Task.sleep(for: .milliseconds(20))
        #expect(channel.writtenData.first == Data("ls\n".utf8))
        await session.close()
    }

    @Test("尺寸变化透传为 resize")
    func forwardsResize() async throws {
        let channel = TestShellChannel()
        let transcript = TerminalTranscript()
        let session = TerminalSession(
            channel: channel,
            transcript: transcript,
            generation: 1,
            resizeDebounceMillis: 10
        )
        try await session.resize(cols: 120, rows: 40)
        #expect(await waitUntil { !channel.resizeSizes.isEmpty })
        #expect(channel.resizeSizes.first == TermSize(cols: 120, rows: 40))
        await session.close()
    }

    @Test("键盘动画产生的连续尺寸变化只发送最终尺寸")
    func coalescesBurstResizeToLatestSize() async throws {
        let channel = TestShellChannel()
        let transcript = TerminalTranscript()
        let session = TerminalSession(
            channel: channel,
            transcript: transcript,
            generation: 1,
            resizeDebounceMillis: 10
        )

        try await session.resize(cols: 80, rows: 24)
        try await session.resize(cols: 80, rows: 20)
        try await session.resize(cols: 80, rows: 16)
        #expect(await waitUntil { !channel.resizeSizes.isEmpty })

        #expect(channel.resizeSizes == [TermSize(cols: 80, rows: 16)])
        await session.close()
    }

    @Test("输入写入失败会抛错并发布失败生命周期")
    func inputFailurePublishesLifecycleEvent() async {
        let channel = TestShellChannel()
        channel.writeError = TestShellError()
        let transcript = TerminalTranscript()
        let session = TerminalSession(channel: channel, transcript: transcript, generation: 1)
        var iterator = session.lifecycleEvents.makeAsyncIterator()

        do {
            try await session.send(Array("bad\n".utf8))
            Issue.record("写入错误不应被吞掉")
        } catch {
            #expect(error is TestShellError)
        }

        guard case .failed? = await iterator.next() else {
            Issue.record("应先收到失败生命周期事件")
            return
        }
    }

    @Test("通道 EOF 在最终输出 flush 后发布关闭事件")
    func eofFlushesOutputBeforeClosedLifecycle() async throws {
        let channel = TestShellChannel()
        let transcript = TerminalTranscript()
        await transcript.activateGeneration(1)
        let session = TerminalSession(channel: channel, transcript: transcript, generation: 1, frameIntervalMillis: 100)
        let attachment = await transcript.attach()
        var render = attachment.events.makeAsyncIterator()
        _ = await render.next()
        _ = await render.next()
        var lifecycle = session.lifecycleEvents.makeAsyncIterator()

        await session.start()
        channel.emit("last\n")
        channel.finish()

        #expect(await render.next() == .liveBytes(Array("last\n".utf8)))
        #expect(await lifecycle.next() == .closed)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
