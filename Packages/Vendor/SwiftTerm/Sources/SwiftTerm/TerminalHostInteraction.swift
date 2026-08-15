// Conn host boundary. Keep this file platform-neutral so the routing contract
// can be verified by SwiftTerm's package tests.

import Foundation

public enum TerminalMouseEncoding: Sendable, Equatable {
    case x10
    case utf8
    case sgr
    case urxvt
    case sgrPixel
}

public struct TerminalInteractionHit: Sendable, Equatable {
    public let column: Int
    public let row: Int
    public let pixelX: Int
    public let pixelY: Int

    public init(column: Int, row: Int, pixelX: Int, pixelY: Int) {
        self.column = column
        self.row = row
        self.pixelX = pixelX
        self.pixelY = pixelY
    }
}

public struct TerminalModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = TerminalModifiers(rawValue: 1 << 0)
    public static let meta = TerminalModifiers(rawValue: 1 << 1)
    public static let control = TerminalModifiers(rawValue: 1 << 2)
}

public enum TerminalWheelDirection: Sendable, Equatable {
    case up
    case down
}

public enum TerminalCursorDirection: Sendable, Equatable {
    case up
    case down
    case left
    case right
}

public enum TerminalPointerEvent: Sendable, Equatable {
    case press(button: Int)
    case release(button: Int)
    case motion(button: Int)
}

public struct TerminalHostProtocolState: Sendable, Equatable {
    public let revision: UInt64
    public let isAlternateBuffer: Bool
    public let mouseMode: Terminal.MouseMode
    public let mouseEncoding: TerminalMouseEncoding
    public let bracketedPasteEnabled: Bool
    public let focusReportingEnabled: Bool
    public let synchronizedOutputEnabled: Bool
    public let applicationCursorEnabled: Bool
    public let columns: Int
    public let rows: Int
}

struct TerminalHostProtocolSignature: Equatable {
    let isAlternateBuffer: Bool
    let mouseMode: Terminal.MouseMode
    let mouseEncoding: TerminalMouseEncoding
    let bracketedPasteEnabled: Bool
    let focusReportingEnabled: Bool
    let synchronizedOutputEnabled: Bool
    let applicationCursorEnabled: Bool
    let columns: Int
    let rows: Int
}

public enum TerminalSnapshotScope: Sendable, Equatable {
    case visible
    case normalHistory
}

public enum TerminalSnapshotColor: Sendable, Equatable {
    case ansi256(UInt8)
    case trueColor(red: UInt8, green: UInt8, blue: UInt8)
    case defaultForeground
    case defaultBackground
}

public struct TerminalSnapshotCellStyle: Sendable, Equatable {
    public let foreground: TerminalSnapshotColor
    public let background: TerminalSnapshotColor
    public let characterStyle: UInt8
    public let underlineStyle: UInt8
}

public struct TerminalSnapshotStyleRun: Sendable, Equatable {
    public let range: Range<Int>
    public let style: TerminalSnapshotCellStyle
}

public struct TerminalBufferSnapshotLine: Sendable, Equatable {
    public let text: String
    public let cellColumnToUTF16Offset: [Int]
    public let styles: [TerminalSnapshotStyleRun]
    public let isWrapped: Bool
}

public struct TerminalBufferSnapshot: Sendable, Equatable {
    public let scope: TerminalSnapshotScope
    public let protocolRevision: UInt64
    public let columns: Int
    public let rows: Int
    public let sourceStartLine: Int
    public let visibleLineRange: Range<Int>
    public let lines: [TerminalBufferSnapshotLine]
}

extension Terminal {
    /// Hard parser boundary for decoded OSC 52 writes. A host may enforce a
    /// smaller policy limit, but the emulator never allocates beyond this cap.
    public static let osc52MaximumDecodedBytes = 1_048_576
    static let osc52MaximumEncodedBytes = ((osc52MaximumDecodedBytes + 2) / 3) * 4
    static let osc52MaximumSequenceBytes = osc52MaximumEncodedBytes + 64

    public var hostProtocolState: TerminalHostProtocolState {
        refreshHostProtocolStateIfNeeded()
        return makeHostProtocolState()
    }

    func currentHostProtocolSignature() -> TerminalHostProtocolSignature {
        TerminalHostProtocolSignature(
            isAlternateBuffer: isCurrentBufferAlternate,
            mouseMode: mouseMode,
            mouseEncoding: hostMouseEncoding,
            bracketedPasteEnabled: bracketedPasteMode,
            focusReportingEnabled: sendFocus,
            synchronizedOutputEnabled: synchronizedOutputActive,
            applicationCursorEnabled: applicationCursor,
            columns: cols,
            rows: rows
        )
    }

    func refreshHostProtocolStateIfNeeded() {
        let signature = currentHostProtocolSignature()
        guard let previous = hostProtocolSignatureStorage else {
            hostProtocolSignatureStorage = signature
            return
        }
        guard previous != signature else {
            return
        }
        hostProtocolSignatureStorage = signature
        hostProtocolRevisionStorage &+= 1
        onHostProtocolStateChanged?(makeHostProtocolState())
    }

    private func makeHostProtocolState() -> TerminalHostProtocolState {
        let signature = currentHostProtocolSignature()
        return TerminalHostProtocolState(
            revision: hostProtocolRevisionStorage,
            isAlternateBuffer: signature.isAlternateBuffer,
            mouseMode: signature.mouseMode,
            mouseEncoding: signature.mouseEncoding,
            bracketedPasteEnabled: signature.bracketedPasteEnabled,
            focusReportingEnabled: signature.focusReportingEnabled,
            synchronizedOutputEnabled: signature.synchronizedOutputEnabled,
            applicationCursorEnabled: signature.applicationCursorEnabled,
            columns: signature.columns,
            rows: signature.rows
        )
    }

    private var hostMouseEncoding: TerminalMouseEncoding {
        switch mouseProtocol {
        case .x10: .x10
        case .utf8: .utf8
        case .sgr: .sgr
        case .urxvt: .urxvt
        case .sgrPixel: .sgrPixel
        }
    }

    public func paste(text: String) {
        var bytes: [UInt8] = []
        if bracketedPasteMode {
            bytes.append(contentsOf: EscapeSequences.bracketedPasteStart)
        }
        bytes.append(contentsOf: text.utf8)
        if bracketedPasteMode {
            bytes.append(contentsOf: EscapeSequences.bracketedPasteEnd)
        }
        guard !bytes.isEmpty else { return }
        tdel?.send(source: self, data: bytes[...])
    }

    public func sendHostCursorKey(_ direction: TerminalCursorDirection, count: Int) {
        let repeatCount = min(max(count, 0), 64)
        guard repeatCount > 0 else { return }
        let final: UInt8
        switch direction {
        case .up: final = UInt8(ascii: "A")
        case .down: final = UInt8(ascii: "B")
        case .right: final = UInt8(ascii: "C")
        case .left: final = UInt8(ascii: "D")
        }
        let prefix = applicationCursor ? [UInt8(0x1b), UInt8(ascii: "O")] : cc.CSI
        let sequence = prefix + [final]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(sequence.count * repeatCount)
        for _ in 0..<repeatCount {
            bytes.append(contentsOf: sequence)
        }
        tdel?.send(source: self, data: bytes[...])
    }

    public func sendHostWheel(
        direction: TerminalWheelDirection,
        count: Int,
        at hit: TerminalInteractionHit,
        modifiers: TerminalModifiers
    ) {
        let repeatCount = min(max(count, 0), 64)
        guard repeatCount > 0, mouseMode != .off else { return }
        let button = direction == .up ? 4 : 5
        let target = clampedHostHit(hit)
        let flags = encodeButton(
            button: button,
            release: false,
            shift: modifiers.contains(.shift),
            meta: modifiers.contains(.meta),
            control: modifiers.contains(.control)
        )
        for _ in 0..<repeatCount {
            sendEvent(
                buttonFlags: flags,
                x: target.column,
                y: target.row,
                pixelX: target.pixelX,
                pixelY: target.pixelY
            )
        }
    }

    public func sendHostPointer(
        _ event: TerminalPointerEvent,
        at hit: TerminalInteractionHit,
        modifiers: TerminalModifiers
    ) {
        guard mouseMode != .off else { return }
        let target = clampedHostHit(hit)
        let button: Int
        let release: Bool
        let motion: Bool
        switch event {
        case let .press(value):
            button = value; release = false; motion = false
        case let .release(value):
            button = value; release = true; motion = false
        case let .motion(value):
            button = value; release = false; motion = true
        }
        let flags = encodeButton(
            button: min(max(button, 0), 2),
            release: release,
            shift: modifiers.contains(.shift),
            meta: modifiers.contains(.meta),
            control: modifiers.contains(.control)
        )
        if motion {
            sendMotion(
                buttonFlags: flags,
                x: target.column,
                y: target.row,
                pixelX: target.pixelX,
                pixelY: target.pixelY
            )
        } else {
            sendEvent(
                buttonFlags: flags,
                x: target.column,
                y: target.row,
                pixelX: target.pixelX,
                pixelY: target.pixelY
            )
        }
    }

    private func clampedHostHit(_ hit: TerminalInteractionHit) -> TerminalInteractionHit {
        TerminalInteractionHit(
            column: min(max(hit.column, 0), max(cols - 1, 0)),
            row: min(max(hit.row, 0), max(rows - 1, 0)),
            pixelX: max(hit.pixelX, 0),
            pixelY: max(hit.pixelY, 0)
        )
    }

    public func makeHostSnapshot(_ scope: TerminalSnapshotScope) -> TerminalBufferSnapshot {
        let selectedBuffer: Buffer
        let start: Int
        let end: Int
        let visible: Range<Int>

        switch scope {
        case .visible:
            selectedBuffer = buffer
            start = min(max(selectedBuffer.yDisp, 0), selectedBuffer.lines.count)
            end = min(start + rows, selectedBuffer.lines.count)
            visible = 0..<(end - start)
        case .normalHistory:
            selectedBuffer = normalBuffer
            start = 0
            end = selectedBuffer.lines.count
            let lower = min(max(selectedBuffer.yDisp, 0), end)
            visible = lower..<min(lower + rows, end)
        }

        var snapshotLines: [TerminalBufferSnapshotLine] = []
        snapshotLines.reserveCapacity(max(end - start, 0))
        if start < end {
            for index in start..<end {
                snapshotLines.append(makeHostSnapshotLine(selectedBuffer.lines[index], columns: selectedBuffer.cols))
            }
        }

        return TerminalBufferSnapshot(
            scope: scope,
            protocolRevision: hostProtocolState.revision,
            columns: selectedBuffer.cols,
            rows: selectedBuffer.rows,
            sourceStartLine: start,
            visibleLineRange: visible,
            lines: snapshotLines
        )
    }

    private func makeHostSnapshotLine(_ line: BufferLine, columns: Int) -> TerminalBufferSnapshotLine {
        let trimmedLength = min(max(line.getTrimmedLength(), 0), columns)
        var text = ""
        var offsets = Array(repeating: 0, count: columns + 1)
        var utf16Offset = 0
        var previousWideStart = 0
        var styles: [TerminalSnapshotStyleRun] = []
        var activeStyle: TerminalSnapshotCellStyle?
        var activeStyleStart = 0

        for column in 0..<columns {
            let cell = line[column]
            if column > 0, cell.code == 0, line[column - 1].width == 2 {
                offsets[column] = previousWideStart
            } else {
                offsets[column] = utf16Offset
                previousWideStart = utf16Offset
                if column < trimmedLength {
                    let character = getCharacter(for: cell)
                    text.append(character)
                    utf16Offset += String(character).utf16.count
                }
            }

            let style = snapshotStyle(cell.attribute)
            if activeStyle != style {
                if let activeStyle {
                    styles.append(TerminalSnapshotStyleRun(range: activeStyleStart..<column, style: activeStyle))
                }
                activeStyle = style
                activeStyleStart = column
            }
        }
        offsets[columns] = utf16Offset
        if let activeStyle {
            styles.append(TerminalSnapshotStyleRun(range: activeStyleStart..<columns, style: activeStyle))
        }

        return TerminalBufferSnapshotLine(
            text: text,
            cellColumnToUTF16Offset: offsets,
            styles: styles,
            isWrapped: line.isWrapped
        )
    }

    private func snapshotStyle(_ attribute: Attribute) -> TerminalSnapshotCellStyle {
        TerminalSnapshotCellStyle(
            foreground: snapshotColor(attribute.fg, foreground: true),
            background: snapshotColor(attribute.bg, foreground: false),
            characterStyle: attribute.style.rawValue,
            underlineStyle: attribute.underlineStyle.rawValue
        )
    }

    private func snapshotColor(_ color: Attribute.Color, foreground: Bool) -> TerminalSnapshotColor {
        switch color {
        case let .ansi256(code): .ansi256(code)
        case let .trueColor(red, green, blue): .trueColor(red: red, green: green, blue: blue)
        case .defaultColor: foreground ? .defaultForeground : .defaultBackground
        case .defaultInvertedColor: foreground ? .defaultBackground : .defaultForeground
        }
    }
}
