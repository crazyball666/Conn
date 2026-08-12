import Foundation

package enum TmuxSnapshotCodecError: Error, Sendable, Equatable {
    case invalidRecord
    case unterminatedField
    case unterminatedEscape
    case invalidUTF8
    case fieldCountMismatch(expected: Int, actual: Int)
    case outputTooLarge(limit: Int)
    case tooManyRecords(limit: Int)
    case tooManyFields(limit: Int)
    case fieldTooLong(limit: Int)
    case missingLegacyField
}

package struct TmuxSnapshotCodecLimits: Sendable, Equatable {
    package static let `default` = Self(
        maxOutputBytes: 4 * 1_024 * 1_024,
        maxRecords: 16_384,
        maxFieldsPerRecord: 32,
        maxFieldBytes: 64 * 1_024
    )

    package let maxOutputBytes: Int
    package let maxRecords: Int
    package let maxFieldsPerRecord: Int
    package let maxFieldBytes: Int

    package init(
        maxOutputBytes: Int,
        maxRecords: Int,
        maxFieldsPerRecord: Int,
        maxFieldBytes: Int
    ) {
        precondition(maxOutputBytes > 0)
        precondition(maxRecords > 0)
        precondition(maxFieldsPerRecord > 0)
        precondition(maxFieldBytes >= 0)
        self.maxOutputBytes = maxOutputBytes
        self.maxRecords = maxRecords
        self.maxFieldsPerRecord = maxFieldsPerRecord
        self.maxFieldBytes = maxFieldBytes
    }
}

/// Decodes records rendered with a format such as `"#{q:session_id}" "#{q:session_name}"`.
/// tmux's `q:` modifier prefixes shell-special bytes with a backslash. Since that includes
/// LF, command output may be split into multiple parser events in the middle of one field;
/// this decoder reconstructs those boundaries before interpreting escapes.
package struct TmuxQuotedSnapshotCodec: Sendable {
    private enum State {
        case expectingField
        case inField
        case escaped
        case afterField
        case expectingNextField
    }

    private let limits: TmuxSnapshotCodecLimits

    package init(limits: TmuxSnapshotCodecLimits = .default) {
        self.limits = limits
    }

    package func decode(
        commandOutputLines: [Data],
        expectedFieldCount: Int
    ) throws -> [[String]] {
        guard expectedFieldCount > 0 else {
            throw TmuxSnapshotCodecError.invalidRecord
        }
        guard expectedFieldCount <= limits.maxFieldsPerRecord else {
            throw TmuxSnapshotCodecError.tooManyFields(limit: limits.maxFieldsPerRecord)
        }
        guard !commandOutputLines.isEmpty else { return [] }

        let wire = try joinedLines(commandOutputLines, limit: limits.maxOutputBytes)
        guard !wire.isEmpty else {
            throw TmuxSnapshotCodecError.invalidRecord
        }

        var records: [[String]] = []
        var record: [String] = []
        var field = Data()
        var state: State = .expectingField

        for byte in wire {
            switch state {
            case .expectingField:
                guard byte == UInt8(ascii: "\"") else {
                    throw TmuxSnapshotCodecError.invalidRecord
                }
                field.removeAll(keepingCapacity: true)
                state = .inField

            case .inField:
                switch byte {
                case UInt8(ascii: "\\"):
                    state = .escaped
                case UInt8(ascii: "\""):
                    try appendField(field, to: &record)
                    state = .afterField
                case UInt8(ascii: "\n"):
                    throw TmuxSnapshotCodecError.invalidRecord
                default:
                    try append(byte, to: &field)
                }

            case .escaped:
                try append(byte, to: &field)
                state = .inField

            case .afterField:
                switch byte {
                case UInt8(ascii: " "):
                    state = .expectingNextField
                case UInt8(ascii: "\n"):
                    try appendRecord(
                        &record,
                        expectedFieldCount: expectedFieldCount,
                        to: &records
                    )
                    state = .expectingField
                default:
                    throw TmuxSnapshotCodecError.invalidRecord
                }

            case .expectingNextField:
                guard byte == UInt8(ascii: "\"") else {
                    throw TmuxSnapshotCodecError.invalidRecord
                }
                field.removeAll(keepingCapacity: true)
                state = .inField
            }
        }

        switch state {
        case .afterField:
            try appendRecord(
                &record,
                expectedFieldCount: expectedFieldCount,
                to: &records
            )
        case .inField:
            throw TmuxSnapshotCodecError.unterminatedField
        case .escaped:
            throw TmuxSnapshotCodecError.unterminatedEscape
        case .expectingField, .expectingNextField:
            throw TmuxSnapshotCodecError.invalidRecord
        }
        return records
    }

    private func append(_ byte: UInt8, to field: inout Data) throws {
        guard field.count < limits.maxFieldBytes else {
            throw TmuxSnapshotCodecError.fieldTooLong(limit: limits.maxFieldBytes)
        }
        field.append(byte)
    }

    private func appendField(_ field: Data, to record: inout [String]) throws {
        guard record.count < limits.maxFieldsPerRecord else {
            throw TmuxSnapshotCodecError.tooManyFields(limit: limits.maxFieldsPerRecord)
        }
        guard let value = String(data: field, encoding: .utf8) else {
            throw TmuxSnapshotCodecError.invalidUTF8
        }
        record.append(value)
    }

    private func appendRecord(
        _ record: inout [String],
        expectedFieldCount: Int,
        to records: inout [[String]]
    ) throws {
        guard record.count == expectedFieldCount else {
            throw TmuxSnapshotCodecError.fieldCountMismatch(
                expected: expectedFieldCount,
                actual: record.count
            )
        }
        guard records.count < limits.maxRecords else {
            throw TmuxSnapshotCodecError.tooManyRecords(limit: limits.maxRecords)
        }
        records.append(record)
        record.removeAll(keepingCapacity: true)
    }
}

/// Legacy tmux versions query each untrusted text property independently. This API cannot
/// decode a delimiter-separated row by design, so a remote value containing any separator
/// cannot shift neighboring fields.
package struct TmuxLegacySnapshotCodec: Sendable {
    private let maxFieldBytes: Int

    package init(maxFieldBytes: Int = 64 * 1_024) {
        precondition(maxFieldBytes >= 0)
        self.maxFieldBytes = maxFieldBytes
    }

    package func decodeSingleField(commandOutputLines: [Data]) throws -> String {
        guard !commandOutputLines.isEmpty else {
            throw TmuxSnapshotCodecError.missingLegacyField
        }
        let field: Data
        do {
            field = try joinedLines(commandOutputLines, limit: maxFieldBytes)
        } catch TmuxSnapshotCodecError.outputTooLarge {
            throw TmuxSnapshotCodecError.fieldTooLong(limit: maxFieldBytes)
        }
        guard let value = String(data: field, encoding: .utf8) else {
            throw TmuxSnapshotCodecError.invalidUTF8
        }
        return value
    }
}

private func joinedLines(_ lines: [Data], limit: Int) throws -> Data {
    var byteCount = max(lines.count - 1, 0)
    for line in lines {
        let (sum, overflow) = byteCount.addingReportingOverflow(line.count)
        guard !overflow, sum <= limit else {
            throw TmuxSnapshotCodecError.outputTooLarge(limit: limit)
        }
        byteCount = sum
    }

    var result = Data()
    result.reserveCapacity(byteCount)
    for (index, line) in lines.enumerated() {
        if index > 0 {
            result.append(UInt8(ascii: "\n"))
        }
        result.append(line)
    }
    return result
}
