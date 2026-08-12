import Foundation

/// A byte-oriented parser for tmux Control Mode. It accepts arbitrary transport chunks and
/// does not decode command output or pane output as UTF-8.
package struct TmuxProtocolParser: Sendable {
    private static let beginGuardPrefix = Data("%begin".utf8)
    private static let endGuardPrefix = Data("%end".utf8)
    private static let errorGuardPrefix = Data("%error".utf8)

    private enum State: Sendable {
        case awaitingStart
        case active
        case awaitingEnd
        case ended
        case failed
    }

    private let dialect: TmuxProtocolDialect
    private let limits: TmuxProtocolParserLimits
    private var state: State = .awaitingStart
    private var startMarkerCandidate = Data()
    private var confirmedPreambleBytes = 0
    private var endMarkerCandidate = Data()
    private var lineBuffer = Data()
    private var activeCommandGuard: TmuxCommandGuard?

    package init(
        dialect: TmuxProtocolDialect,
        limits: TmuxProtocolParserLimits = .default
    ) {
        self.dialect = dialect
        self.limits = limits
    }

    package mutating func feed(_ data: Data) throws -> [TmuxProtocolEvent] {
        guard state != .failed else {
            throw TmuxProtocolParserError.parserFailed
        }
        guard state != .ended || data.isEmpty else {
            state = .failed
            throw TmuxProtocolParserError.unexpectedDataAfterEnd
        }

        do {
            var events: [TmuxProtocolEvent] = []
            for byte in data {
                try consume(byte, events: &events)
            }
            return events
        } catch let error as TmuxProtocolParserError {
            state = .failed
            throw error
        } catch {
            state = .failed
            throw error
        }
    }

    package mutating func finish() throws -> [TmuxProtocolEvent] {
        let error: TmuxProtocolParserError
        switch state {
        case .awaitingStart:
            error = .missingProtocolStart
        case .active where activeCommandGuard != nil:
            error = .incompleteCommandBlock
        case .active where !lineBuffer.isEmpty:
            error = .incompleteLine
        case .active:
            error = .missingProtocolEnd
        case .awaitingEnd:
            error = .missingProtocolEnd
        case .ended:
            return []
        case .failed:
            throw TmuxProtocolParserError.parserFailed
        }

        state = .failed
        throw error
    }

    private mutating func consume(
        _ byte: UInt8,
        events: inout [TmuxProtocolEvent]
    ) throws {
        switch state {
        case .awaitingStart:
            try consumeBeforeStart(byte, events: &events)
        case .active:
            try consumeActive(byte, events: &events)
        case .awaitingEnd:
            try consumeEndMarker(byte, events: &events)
        case .ended:
            throw TmuxProtocolParserError.unexpectedDataAfterEnd
        case .failed:
            throw TmuxProtocolParserError.parserFailed
        }
    }

    private mutating func consumeBeforeStart(
        _ byte: UInt8,
        events: inout [TmuxProtocolEvent]
    ) throws {
        startMarkerCandidate.append(byte)

        if startMarkerCandidate == TmuxProtocolMarker.start {
            startMarkerCandidate.removeAll(keepingCapacity: true)
            state = .active
            events.append(.protocolStarted)
            return
        }

        let retainedCount = longestStartMarkerPrefixAtSuffix(of: startMarkerCandidate)
        let newlyConfirmed = startMarkerCandidate.count - retainedCount
        if newlyConfirmed > 0 {
            confirmedPreambleBytes += newlyConfirmed
            guard confirmedPreambleBytes <= limits.maxPreambleBytes else {
                throw TmuxProtocolParserError.preambleTooLong(limit: limits.maxPreambleBytes)
            }
            startMarkerCandidate.removeFirst(newlyConfirmed)
        }
    }

    private func longestStartMarkerPrefixAtSuffix(of data: Data) -> Int {
        let maximum = min(data.count, TmuxProtocolMarker.start.count - 1)
        guard maximum > 0 else { return 0 }

        for length in stride(from: maximum, through: 1, by: -1) {
            if data.suffix(length).elementsEqual(TmuxProtocolMarker.start.prefix(length)) {
                return length
            }
        }
        return 0
    }

    private mutating func consumeActive(
        _ byte: UInt8,
        events: inout [TmuxProtocolEvent]
    ) throws {
        if byte == UInt8(ascii: "\n") {
            var line = lineBuffer
            lineBuffer.removeAll(keepingCapacity: true)
            if line.last == UInt8(ascii: "\r") {
                line.removeLast()
            }
            try consumeLine(line, events: &events)
            return
        }

        lineBuffer.append(byte)
        guard lineBuffer.count <= limits.maxLineBytes else {
            throw TmuxProtocolParserError.lineTooLong(limit: limits.maxLineBytes)
        }
    }

    private mutating func consumeEndMarker(
        _ byte: UInt8,
        events: inout [TmuxProtocolEvent]
    ) throws {
        endMarkerCandidate.append(byte)
        guard TmuxProtocolMarker.end.starts(with: endMarkerCandidate) else {
            throw TmuxProtocolParserError.unexpectedProtocolData
        }
        if endMarkerCandidate == TmuxProtocolMarker.end {
            endMarkerCandidate.removeAll(keepingCapacity: true)
            state = .ended
            events.append(.protocolEnded)
        }
    }

    private mutating func consumeLine(
        _ line: Data,
        events: inout [TmuxProtocolEvent]
    ) throws {
        if let expectedGuard = activeCommandGuard {
            if guardPayload(in: line, prefix: Self.beginGuardPrefix) != nil {
                throw TmuxProtocolParserError.nestedCommandBlock
            }
            if let payload = guardPayload(in: line, prefix: Self.endGuardPrefix) {
                let actualGuard = try parseCommandGuard(payload)
                guard actualGuard == expectedGuard else {
                    throw TmuxProtocolParserError.commandGuardMismatch(
                        expected: expectedGuard,
                        actual: actualGuard
                    )
                }
                activeCommandGuard = nil
                events.append(.commandEnd(actualGuard))
                return
            }
            if let payload = guardPayload(in: line, prefix: Self.errorGuardPrefix) {
                let actualGuard = try parseCommandGuard(payload)
                guard actualGuard == expectedGuard else {
                    throw TmuxProtocolParserError.commandGuardMismatch(
                        expected: expectedGuard,
                        actual: actualGuard
                    )
                }
                activeCommandGuard = nil
                events.append(.commandError(actualGuard))
                return
            }
            events.append(.commandOutput(line))
            return
        }

        let controlLine = try splitControlLine(line)
        switch controlLine.name {
        case "begin":
            let guardValue = try parseCommandGuard(controlLine.payload)
            activeCommandGuard = guardValue
            events.append(.commandBegin(guardValue))
        case "end", "error":
            throw TmuxProtocolParserError.unmatchedCommandTerminator
        case "output":
            events.append(.notification(try parsePaneOutput(controlLine.payload)))
        case "extended-output":
            events.append(.notification(try parseExtendedPaneOutput(controlLine.payload)))
        case "exit":
            state = .awaitingEnd
            events.append(.notification(.exit(reason: controlLine.payload)))
        default:
            if let known = TmuxKnownNotification(rawValue: controlLine.name) {
                events.append(.notification(.known(known, payload: controlLine.payload)))
            } else {
                events.append(.notification(.unknown(
                    name: controlLine.name,
                    payload: controlLine.payload
                )))
            }
        }
    }

    /// Command output is arbitrary bytes. Only the three reserved guard records may be
    /// interpreted while a block is open; all other percent-prefixed lines stay opaque.
    private func guardPayload(in line: Data, prefix: Data) -> Data? {
        if line == prefix {
            return Data()
        }
        guard line.count > prefix.count,
              line.starts(with: prefix),
              line[line.index(line.startIndex, offsetBy: prefix.count)] == UInt8(ascii: " ")
        else {
            return nil
        }
        return Data(line.dropFirst(prefix.count + 1))
    }

    private func splitControlLine(_ line: Data) throws -> (name: String, payload: Data) {
        guard line.first == UInt8(ascii: "%") else {
            throw TmuxProtocolParserError.unexpectedProtocolData
        }

        let content = line.dropFirst()
        let separator = content.firstIndex(of: UInt8(ascii: " "))
        let nameBytes = separator.map { content[..<$0] } ?? content[...]
        guard !nameBytes.isEmpty,
              let name = String(data: Data(nameBytes), encoding: .utf8)
        else {
            throw TmuxProtocolParserError.unexpectedProtocolData
        }

        let payload: Data
        if let separator {
            payload = Data(content[content.index(after: separator)...])
        } else {
            payload = Data()
        }
        return (name, payload)
    }

    private func parseCommandGuard(_ payload: Data) throws -> TmuxCommandGuard {
        let fields = payload.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: true)
        let expectedCount = dialect.commandGuardShape == .twoFields ? 2 : 3
        guard fields.count == expectedCount,
              let time = parseInt64(fields[0]),
              time >= 0,
              let commandNumber = parseUInt64(fields[1])
        else {
            throw TmuxProtocolParserError.invalidCommandGuard
        }

        let flags: UInt64?
        if expectedCount == 3 {
            guard let parsedFlags = parseUInt64(fields[2]) else {
                throw TmuxProtocolParserError.invalidCommandGuard
            }
            flags = parsedFlags
        } else {
            flags = nil
        }
        return TmuxCommandGuard(time: time, commandNumber: commandNumber, flags: flags)
    }

    private func parsePaneOutput(_ payload: Data) throws -> TmuxNotification {
        let fields = splitFirstField(payload)
        guard let encodedOutput = fields.remainder,
              let paneID = parsePaneID(fields.field)
        else {
            throw TmuxProtocolParserError.invalidPaneOutput
        }
        return .paneOutput(paneID, try decodePaneOutput(encodedOutput))
    }

    private func parseExtendedPaneOutput(_ payload: Data) throws -> TmuxNotification {
        let paneFields = splitFirstField(payload)
        guard let remainder = paneFields.remainder,
              let paneID = parsePaneID(paneFields.field)
        else {
            throw TmuxProtocolParserError.invalidPaneOutput
        }

        let ageFields = splitFirstField(remainder)
        guard let delimiterAndOutput = ageFields.remainder,
              let age = parseInt(ageFields.field),
              age >= 0,
              delimiterAndOutput.starts(with: [UInt8(ascii: ":"), UInt8(ascii: " ")])
        else {
            throw TmuxProtocolParserError.invalidPaneOutput
        }
        let encodedOutput = delimiterAndOutput.dropFirst(2)
        return .extendedPaneOutput(
            paneID,
            ageMilliseconds: age,
            data: try decodePaneOutput(Data(encodedOutput))
        )
    }

    private func splitFirstField(_ data: Data) -> (field: Data, remainder: Data?) {
        guard let separator = data.firstIndex(of: UInt8(ascii: " ")) else {
            return (data, nil)
        }
        return (
            Data(data[..<separator]),
            Data(data[data.index(after: separator)...])
        )
    }

    private func parsePaneID(_ data: Data) -> TmuxPaneID? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        return TmuxPaneID(rawValue: value)
    }

    private func decodePaneOutput(_ encoded: Data) throws -> Data {
        let bytes = Array(encoded)
        var decoded = Data()
        decoded.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                guard index + 3 < bytes.count else {
                    throw TmuxProtocolParserError.invalidPaneOutput
                }
                let digits = bytes[(index + 1) ... (index + 3)]
                guard digits.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "7")).contains($0) })
                else {
                    throw TmuxProtocolParserError.invalidPaneOutput
                }
                let value = Int(digits[digits.startIndex] - UInt8(ascii: "0")) * 64
                    + Int(digits[digits.index(after: digits.startIndex)] - UInt8(ascii: "0")) * 8
                    + Int(digits[digits.index(digits.startIndex, offsetBy: 2)] - UInt8(ascii: "0"))
                guard value <= UInt8.max else {
                    throw TmuxProtocolParserError.invalidPaneOutput
                }
                decoded.append(UInt8(value))
                index += 4
            } else {
                guard byte >= UInt8(ascii: " ") else {
                    throw TmuxProtocolParserError.invalidPaneOutput
                }
                decoded.append(byte)
                index += 1
            }
        }
        return decoded
    }

    private func parseInt64<T: Collection>(_ bytes: T) -> Int64? where T.Element == UInt8 {
        Int64(String(decoding: bytes, as: UTF8.self))
    }

    private func parseUInt64<T: Collection>(_ bytes: T) -> UInt64? where T.Element == UInt8 {
        UInt64(String(decoding: bytes, as: UTF8.self))
    }

    private func parseInt<T: Collection>(_ bytes: T) -> Int? where T.Element == UInt8 {
        Int(String(decoding: bytes, as: UTF8.self))
    }
}
