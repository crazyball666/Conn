import ConnMultiplexer
import Foundation
import SwiftTerm

public struct TerminalReviewIdentity: Sendable, Equatable {
    public let terminalGeneration: UInt64
    public let attachmentGeneration: UInt64
    public let sourceRevision: UInt64

    public init(
        terminalGeneration: UInt64,
        attachmentGeneration: UInt64,
        sourceRevision: UInt64
    ) {
        self.terminalGeneration = terminalGeneration
        self.attachmentGeneration = attachmentGeneration
        self.sourceRevision = sourceRevision
    }
}

public struct TerminalReviewLine: Sendable, Equatable {
    public let text: String
    public let cellColumnToUTF16Offset: [Int]
    public let isWrapped: Bool

    public init(
        text: String,
        cellColumnToUTF16Offset: [Int],
        isWrapped: Bool
    ) {
        self.text = text
        self.cellColumnToUTF16Offset = cellColumnToUTF16Offset
        self.isWrapped = isWrapped
    }
}

/// Frozen, inert text used by the local review/selection surface. It never retains a live
/// terminal buffer and is never fed back into an emulator or remote channel.
public struct TerminalReviewSnapshot: Sendable, Equatable {
    public let identity: TerminalReviewIdentity
    public let lines: [TerminalReviewLine]
    public let visibleLineRange: Range<Int>
    public let isTruncated: Bool
    public let byteCount: Int
    public let text: String

    private let lineUTF16Offsets: [Int]

    public init(
        identity: TerminalReviewIdentity,
        lines: [TerminalReviewLine],
        visibleLineRange: Range<Int>,
        isTruncated: Bool,
        byteCount: Int
    ) {
        self.identity = identity
        self.lines = lines
        self.visibleLineRange = Self.clamped(visibleLineRange, count: lines.count)
        self.isTruncated = isTruncated
        self.byteCount = max(byteCount, 0)

        var result = ""
        var offsets: [Int] = []
        offsets.reserveCapacity(lines.count)
        for index in lines.indices {
            offsets.append(result.utf16.count)
            result.append(lines[index].text)
            if index < lines.index(before: lines.endIndex), !lines[index].isWrapped {
                result.append("\n")
            }
        }
        text = result
        lineUTF16Offsets = offsets
    }

    public init(
        swiftTerm snapshot: TerminalBufferSnapshot,
        terminalGeneration: UInt64,
        attachmentGeneration: UInt64
    ) {
        self.init(
            identity: .init(
                terminalGeneration: terminalGeneration,
                attachmentGeneration: attachmentGeneration,
                sourceRevision: snapshot.protocolRevision
            ),
            lines: snapshot.lines.map(Self.reviewLine),
            visibleLineRange: snapshot.visibleLineRange,
            isTruncated: snapshot.sourceStartLine > 0,
            byteCount: snapshot.lines.reduce(0) { $0 + $1.text.utf8.count }
        )
    }

    public init(
        persistent snapshot: PersistentTerminalHistorySnapshot,
        terminalGeneration: UInt64
    ) {
        self.init(
            identity: .init(
                terminalGeneration: terminalGeneration,
                attachmentGeneration: snapshot.attachmentGeneration,
                sourceRevision: snapshot.stateRevision
            ),
            lines: snapshot.lines.map(Self.reviewLine),
            visibleLineRange: snapshot.visibleLineRange,
            isTruncated: snapshot.isTruncated,
            byteCount: snapshot.byteCount
        )
    }

    public static func sanitizing(
        _ data: Data,
        identity: TerminalReviewIdentity,
        maximumLines: Int,
        maximumBytes: Int
    ) -> TerminalReviewSnapshot {
        let byteLimit = max(maximumBytes, 0)
        let bounded = Data(data.prefix(byteLimit))
        let sanitized = TerminalReviewSanitizer.sanitize(bounded)
        let normalized = String(decoding: sanitized, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var values = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if normalized.hasSuffix("\n"), values.last?.isEmpty == true {
            values.removeLast()
        }
        let lineLimit = max(maximumLines, 0)
        let lineTruncated = values.count > lineLimit
        if lineTruncated {
            values = Array(values.suffix(lineLimit))
        }
        let lines = values.map {
            TerminalReviewLine(
                text: $0,
                cellColumnToUTF16Offset: Array(0 ... $0.utf16.count),
                isWrapped: false
            )
        }
        return .init(
            identity: identity,
            lines: lines,
            visibleLineRange: 0..<lines.count,
            isTruncated: data.count > bounded.count || lineTruncated,
            byteCount: bounded.count
        )
    }

    public func utf16Offset(line: Int, column: Int) -> Int? {
        guard lines.indices.contains(line) else { return nil }
        let mapping = lines[line].cellColumnToUTF16Offset
        guard !mapping.isEmpty else { return lineUTF16Offsets[line] }
        let clampedColumn = min(max(column, 0), mapping.count - 1)
        let local = min(max(mapping[clampedColumn], 0), lines[line].text.utf16.count)
        return lineUTF16Offsets[line] + local
    }

    private static func reviewLine(_ source: TerminalBufferSnapshotLine) -> TerminalReviewLine {
        reviewLine(
            text: source.text,
            mapping: source.cellColumnToUTF16Offset,
            isWrapped: source.isWrapped
        )
    }

    private static func reviewLine(_ source: PersistentTerminalHistoryLine) -> TerminalReviewLine {
        reviewLine(
            text: source.text,
            mapping: source.cellColumnToUTF16Offset,
            isWrapped: source.isWrapped
        )
    }

    private static func reviewLine(
        text: String,
        mapping: [Int],
        isWrapped: Bool
    ) -> TerminalReviewLine {
        let inert = String(decoding: TerminalReviewSanitizer.sanitize(Data(text.utf8)), as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let offsets: [Int]
        if inert == text, !mapping.isEmpty {
            offsets = mapping.map { min(max($0, 0), inert.utf16.count) }
        } else {
            offsets = Array(0 ... inert.utf16.count)
        }
        return TerminalReviewLine(
            text: inert,
            cellColumnToUTF16Offset: offsets,
            isWrapped: isWrapped
        )
    }

    private static func clamped(_ range: Range<Int>, count: Int) -> Range<Int> {
        let lower = min(max(range.lowerBound, 0), count)
        let upper = min(max(range.upperBound, lower), count)
        return lower..<upper
    }
}

private enum TerminalReviewSanitizer {
    private enum State {
        case normal
        case escape
        case csi
        case controlString
        case controlStringEscape
    }

    static func sanitize(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        var state = State.normal
        for byte in data {
            switch state {
            case .normal:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x09, 0x0A, 0x0D:
                    output.append(byte)
                case 0x00 ... 0x1F, 0x7F:
                    break
                default:
                    output.append(byte)
                }
            case .escape:
                switch byte {
                case UInt8(ascii: "["):
                    state = .csi
                case UInt8(ascii: "]"), UInt8(ascii: "P"),
                     UInt8(ascii: "_"), UInt8(ascii: "^"):
                    state = .controlString
                default:
                    state = .normal
                }
            case .csi:
                if (0x40 ... 0x7E).contains(byte) { state = .normal }
            case .controlString:
                if byte == 0x07 {
                    state = .normal
                } else if byte == 0x1B {
                    state = .controlStringEscape
                }
            case .controlStringEscape:
                if byte == UInt8(ascii: "\\") {
                    state = .normal
                } else if byte != 0x1B {
                    state = .controlString
                }
            }
        }
        return output
    }
}
