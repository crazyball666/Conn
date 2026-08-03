import Testing
@testable import ConnTerminal

@Suite("TerminalReplayBuffer — 输出保留")
struct TerminalReplayBufferTests {
    @Test("保留最近的完整行")
    func trimsOldCompleteLines() {
        var buffer = TerminalReplayBuffer(maxLines: 2, maxBytes: 1024)

        buffer.append(Array("one\ntwo\nthree\n".utf8))

        #expect(String(decoding: buffer.snapshot.bytes, as: UTF8.self) == "two\nthree\n")
        #expect(buffer.snapshot.wasTruncated)
    }

    @Test("无换行的长输出按字节上限保留末尾")
    func trimsLongLineByByteLimit() {
        var buffer = TerminalReplayBuffer(maxLines: 100, maxBytes: 4)

        buffer.append(Array("abcdef".utf8))

        #expect(String(decoding: buffer.snapshot.bytes, as: UTF8.self) == "cdef")
        #expect(buffer.snapshot.wasTruncated)
    }
}
