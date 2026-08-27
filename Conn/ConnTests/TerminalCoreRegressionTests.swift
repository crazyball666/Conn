import ConnKit
import ConnMultiplexer
import ConnSSH
@testable import ConnTerminal
import Foundation
import Testing

private actor TerminalCoreWriteGate {
    private var firstWriteStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func blockFirstWrite() async {
        firstWriteStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFirstWriteStarts() async {
        while !firstWriteStarted {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseFirstWrite() {
        continuation?.resume()
        continuation = nil
    }
}

private final class TerminalCoreOrderedChannel: ShellChannel, @unchecked Sendable {
    let output = AsyncThrowingStream<Data, Error> { _ in }
    let gate = TerminalCoreWriteGate()
    private let lock = NSLock()
    private var writes: [Data] = []
    private var writeCount = 0
    private var concurrentWriteCount = 0
    private var maximumConcurrentWriteCount = 0

    func write(_ bytes: Data) async throws {
        let index = lock.withLock { () -> Int in
            let index = writeCount
            writeCount += 1
            concurrentWriteCount += 1
            maximumConcurrentWriteCount = max(
                maximumConcurrentWriteCount,
                concurrentWriteCount
            )
            return index
        }
        if index == 0 {
            await gate.blockFirstWrite()
        }
        lock.withLock {
            writes.append(bytes)
            concurrentWriteCount -= 1
        }
    }

    func resize(_ size: TermSize) async throws {
        _ = size
    }

    func close() async {}

    var writtenData: [Data] {
        lock.withLock { writes }
    }

    var maxConcurrentWrites: Int {
        lock.withLock { maximumConcurrentWriteCount }
    }
}

@Suite("终端核心模拟器回归")
struct TerminalCoreRegressionTests {
    @Test("快速输入按提交顺序串行写入")
    func inputWritesRemainOrdered() async throws {
        let channel = TerminalCoreOrderedChannel()
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

    @Test("慢渲染消费者从最新有界回放恢复")
    func slowRendererResynchronizes() async {
        let transcript = TerminalTranscript(
            maxLines: 100,
            maxBytes: 12,
            maxPendingLiveBytes: 3
        )
        await transcript.activateGeneration(1)
        let attachment = await transcript.attach()

        await transcript.append(Array("1234".utf8), generation: 1)
        await transcript.append(Array("5678".utf8), generation: 1)
        await transcript.append(Array("90ab".utf8), generation: 1)

        var iterator = attachment.events.makeAsyncIterator()
        #expect(await iterator.next() == .replayStarted(requiresReset: true))
        #expect(await iterator.next() == .replayBytes(Array("1234567890ab".utf8)))
        #expect(await iterator.next() == .replayFinished(.default))
    }

    @Test("渲染积压时相邻帧有序合并")
    func adjacentRenderFramesCoalesce() async {
        let transcript = TerminalTranscript(maxPendingLiveBytes: 1024)
        await transcript.activateGeneration(1)
        let attachment = await transcript.attach()
        var iterator = attachment.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        await transcript.append(Array("one".utf8), generation: 1)
        await transcript.append(Array("-two".utf8), generation: 1)
        await transcript.append(Array("-three".utf8), generation: 1)

        #expect(await iterator.next() == .liveBytes(Array("one-two-three".utf8)))
    }

    @Test("碎片化输出按行数和字节上限保留")
    func fragmentedReplayRetainsRecentOutput() {
        var buffer = TerminalReplayBuffer(maxLines: 3, maxBytes: 12)

        for fragment in ["one\n", "two\n", "three\n", "four\n"] {
            buffer.append(Array(fragment.utf8))
        }

        #expect(String(decoding: buffer.snapshot.bytes, as: UTF8.self) == "three\nfour\n")
        #expect(buffer.snapshot.wasTruncated)
    }

    @Test("持久终端目录流仅保留最新状态")
    func persistentCatalogStateIsBounded() async throws {
        let pair = PersistentTerminalCatalogStreams.makeStateStream(of: Int.self)
        pair.continuation.yield(1)
        pair.continuation.yield(2)
        pair.continuation.yield(3)

        var iterator = pair.stream.makeAsyncIterator()
        #expect(try #require(await iterator.next()) == 3)
        pair.continuation.finish()
    }
}
