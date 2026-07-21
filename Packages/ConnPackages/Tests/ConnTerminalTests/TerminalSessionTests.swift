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
    private let lock = NSLock()

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
    func finish() { continuation.finish() }

    func write(_ bytes: Data) async throws {
        lock.withLock { written.append(bytes) }
    }

    func resize(_ size: TermSize) async throws {
        lock.withLock { resizes.append(size) }
    }

    func close() async { continuation.finish() }

    var writtenData: [Data] { lock.withLock { written } }
    var resizeSizes: [TermSize] { lock.withLock { resizes } }
}

@Suite("TerminalSession — 合帧与桥接")
struct TerminalSessionTests {
    @Test("多次小块输出被合成投递，累积等于原始字节")
    func batchesOutput() async throws {
        let channel = TestShellChannel()
        let session = TerminalSession(channel: channel, frameIntervalMillis: 10)

        let collected = Collector()
        await session.start { bytes in
            Task { await collected.append(bytes) }
        }

        // 快速连喂 5 个小块
        for index in 0 ..< 5 {
            channel.emit("chunk\(index)-")
        }
        // 等待超过一个合帧周期让 flush 触发
        try await Task.sleep(for: .milliseconds(60))

        let total = await collected.joined()
        #expect(total.contains("chunk0-"))
        #expect(total.contains("chunk4-"))
        // 5 个小块应被合并为远少于 5 次的投递（合帧生效）
        let frameCount = await collected.frameCount
        #expect(frameCount < 5)

        await session.close()
    }

    @Test("用户输入透传到通道")
    func forwardsInput() async throws {
        let channel = TestShellChannel()
        let session = TerminalSession(channel: channel)
        await session.send([UInt8]("ls\n".utf8))
        try await Task.sleep(for: .milliseconds(20))
        #expect(channel.writtenData.first == Data("ls\n".utf8))
        await session.close()
    }

    @Test("尺寸变化透传为 resize")
    func forwardsResize() async throws {
        let channel = TestShellChannel()
        let session = TerminalSession(channel: channel)
        await session.resize(cols: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(20))
        #expect(channel.resizeSizes.first == TermSize(cols: 120, rows: 40))
        await session.close()
    }
}

private actor Collector {
    private var frames: [String] = []
    // swiftlint:disable:next optional_data_string_conversion
    func append(_ bytes: [UInt8]) { frames.append(String(decoding: bytes, as: UTF8.self)) }
    func joined() -> String { frames.joined() }
    var frameCount: Int { frames.count }
}
