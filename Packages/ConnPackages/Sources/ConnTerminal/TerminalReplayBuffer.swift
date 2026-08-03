import Foundation

/// 终端输出的有界回放缓存。
///
/// 优先从最早的完整行裁剪；没有换行的长输出才按字节裁剪，避免无限占用内存。
public struct TerminalReplayBuffer: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let bytes: [UInt8]
        public let wasTruncated: Bool

        fileprivate init(bytes: [UInt8], wasTruncated: Bool) {
            self.bytes = bytes
            self.wasTruncated = wasTruncated
        }
    }

    private let maxLines: Int
    private let maxBytes: Int
    private var bytes: [UInt8] = []
    private var wasTruncated = false

    public init(maxLines: Int = 10_000, maxBytes: Int = 4 * 1024 * 1024) {
        self.maxLines = max(1, maxLines)
        self.maxBytes = max(1, maxBytes)
    }

    public var snapshot: Snapshot {
        Snapshot(bytes: bytes, wasTruncated: wasTruncated)
    }

    public mutating func append(_ newBytes: [UInt8]) {
        guard !newBytes.isEmpty else { return }
        bytes.append(contentsOf: newBytes)
        trimIfNeeded()
    }

    private mutating func trimIfNeeded() {
        var didTrim = false

        while newlineCount > maxLines, let newline = bytes.firstIndex(of: 0x0A) {
            bytes.removeSubrange(...newline)
            didTrim = true
        }

        while bytes.count > maxBytes, let newline = bytes.firstIndex(of: 0x0A) {
            bytes.removeSubrange(...newline)
            didTrim = true
        }

        if bytes.count > maxBytes {
            bytes.removeFirst(bytes.count - maxBytes)
            didTrim = true
        }

        if didTrim {
            wasTruncated = true
        }
    }

    private var newlineCount: Int {
        bytes.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }
}
