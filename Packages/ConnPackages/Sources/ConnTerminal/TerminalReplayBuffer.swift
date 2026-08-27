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
    private var startIndex = 0
    private var newlineCount = 0
    private var wasTruncated = false

    public init(maxLines: Int = 10000, maxBytes: Int = 4 * 1024 * 1024) {
        self.maxLines = max(1, maxLines)
        self.maxBytes = max(1, maxBytes)
    }

    public var snapshot: Snapshot {
        Snapshot(bytes: Array(bytes[startIndex...]), wasTruncated: wasTruncated)
    }

    public mutating func append(_ newBytes: [UInt8]) {
        guard !newBytes.isEmpty else { return }
        bytes.append(contentsOf: newBytes)
        newlineCount += newBytes.reduce(into: 0) { count, byte in
            if byte == 0x0A {
                count += 1
            }
        }
        trimIfNeeded()
    }

    public mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
        startIndex = 0
        newlineCount = 0
        wasTruncated = false
    }

    private mutating func trimIfNeeded() {
        var didTrim = false

        while newlineCount > maxLines, let newline = nextNewlineIndex {
            startIndex = newline + 1
            newlineCount -= 1
            didTrim = true
        }

        while retainedByteCount > maxBytes, let newline = nextNewlineIndex {
            startIndex = newline + 1
            newlineCount -= 1
            didTrim = true
        }

        if retainedByteCount > maxBytes {
            let removedRange = startIndex ..< (bytes.count - maxBytes)
            newlineCount -= bytes[removedRange].reduce(into: 0) { count, byte in
                if byte == 0x0A {
                    count += 1
                }
            }
            startIndex = removedRange.upperBound
            didTrim = true
        }

        if didTrim {
            wasTruncated = true
        }
        compactStorageIfNeeded()
    }

    private var retainedByteCount: Int {
        bytes.count - startIndex
    }

    private var nextNewlineIndex: Int? {
        guard startIndex < bytes.endIndex else { return nil }
        return bytes[startIndex...].firstIndex(of: 0x0A)
    }

    /// Front trimming only advances an index. Compact occasionally so each append does not
    /// shift a multi-megabyte array while stale capacity is still reclaimed over time.
    private mutating func compactStorageIfNeeded() {
        guard startIndex >= 64 * 1024,
              startIndex >= bytes.count / 2
        else { return }
        bytes.removeSubrange(..<startIndex)
        startIndex = 0
    }
}
