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
    private var closeInvocations = 0
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

    func close() async {
        lock.withLock { closeInvocations += 1 }
        continuation.finish()
    }

    var writtenData: [Data] { lock.withLock { written } }
    var resizeSizes: [TermSize] { lock.withLock { resizes } }
    var closeCount: Int { lock.withLock { closeInvocations } }
}

private actor OrderedWriteGate {
    private var firstWriteContinuation: CheckedContinuation<Void, Never>?
    private var firstWriteStarted = false

    func blockFirstWrite() async {
        firstWriteStarted = true
        await withCheckedContinuation { firstWriteContinuation = $0 }
    }

    func waitUntilFirstWriteStarts() async {
        while !firstWriteStarted {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseFirstWrite() {
        firstWriteContinuation?.resume()
        firstWriteContinuation = nil
    }
}

private final class OrderedWriteShellChannel: ShellChannel, @unchecked Sendable {
    let output = AsyncThrowingStream<Data, Error> { _ in }
    let gate = OrderedWriteGate()
    private let lock = NSLock()
    private var writes: [Data] = []
    private var concurrentWrites = 0
    private var maximumConcurrentWrites = 0
    private var writeIndex = 0

    func write(_ bytes: Data) async throws {
        let index = lock.withLock { () -> Int in
            let index = writeIndex
            writeIndex += 1
            concurrentWrites += 1
            maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
            return index
        }
        if index == 0 {
            await gate.blockFirstWrite()
        }
        lock.withLock {
            writes.append(bytes)
            concurrentWrites -= 1
        }
    }

    func resize(_ size: TermSize) async throws { _ = size }
    func close() async {}

    var writtenData: [Data] { lock.withLock { writes } }
    var maxConcurrentWrites: Int { lock.withLock { maximumConcurrentWrites } }
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

    @Test("并发提交的终端输入严格串行写入")
    func serializesConcurrentInput() async throws {
        let channel = OrderedWriteShellChannel()
        let session = TerminalSession(
            channel: channel,
            transcript: TerminalTranscript(),
            generation: 1
        )

        let first = Task { try await session.send(Array("first".utf8)) }
        await channel.gate.waitUntilFirstWriteStarts()
        let second = Task { try await session.send(Array("second".utf8)) }
        try await Task.sleep(for: .milliseconds(30))

        #expect(channel.writtenData.isEmpty)
        #expect(channel.maxConcurrentWrites == 1)
        await channel.gate.releaseFirstWrite()
        try await first.value
        try await second.value

        #expect(channel.writtenData == [Data("first".utf8), Data("second".utf8)])
        #expect(channel.maxConcurrentWrites == 1)
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
        await session.start()

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
        #expect(await waitUntil { channel.closeCount == 1 })
        #expect(await session.state == .failed)
        await #expect(throws: (any Error).self) {
            try await session.send(Array("after-failure\n".utf8))
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
