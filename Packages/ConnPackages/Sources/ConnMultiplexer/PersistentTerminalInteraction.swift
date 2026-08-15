import Foundation

public enum PersistentTerminalInteractionError: Error, Sendable, Equatable {
    case invalidHistoryLineLimit(Int)
    case invalidHistoryByteLimit(Int)
    case invalidScrollRows(Int)
    case targetMismatch
    case staleAttachmentGeneration
    case staleStateRevision
    case unavailable
    case unsupportedMode
}

public struct PersistentTerminalInteractionTarget: Sendable, Hashable {
    public let providerID: String
    public let workspaceID: String
    public let targetID: String

    public init(providerID: String, workspaceID: String, targetID: String) {
        self.providerID = providerID
        self.workspaceID = workspaceID
        self.targetID = targetID
    }
}

public enum PersistentTerminalInteractionFreshness: Sendable, Equatable {
    case live
    case snapshot
    case stale
}

public enum PersistentTerminalModeCapability: Sendable, Equatable {
    case none
    case scrollable
    case keyDriven
    case unsupported
}

public struct PersistentTerminalInteractionState: Sendable, Equatable {
    public let target: PersistentTerminalInteractionTarget
    public let attachmentGeneration: UInt64
    public let revision: UInt64
    public let freshness: PersistentTerminalInteractionFreshness
    public let isAlternateBuffer: Bool?
    public let modeCapability: PersistentTerminalModeCapability
    public let providerModeID: String?
    public let historyAvailable: Bool
    public let observedAt: Date

    public init(
        target: PersistentTerminalInteractionTarget,
        attachmentGeneration: UInt64,
        revision: UInt64,
        freshness: PersistentTerminalInteractionFreshness,
        isAlternateBuffer: Bool?,
        modeCapability: PersistentTerminalModeCapability,
        providerModeID: String? = nil,
        historyAvailable: Bool,
        observedAt: Date
    ) {
        self.target = target
        self.attachmentGeneration = attachmentGeneration
        self.revision = revision
        self.freshness = freshness
        self.isAlternateBuffer = isAlternateBuffer
        self.modeCapability = modeCapability
        self.providerModeID = providerModeID
        self.historyAvailable = historyAvailable
        self.observedAt = observedAt
    }
}

public struct PersistentTerminalHistoryRequest: Sendable, Equatable {
    public static let maximumLines = 100_000
    public static let maximumBytes = 4 * 1_024 * 1_024

    public let target: PersistentTerminalInteractionTarget
    public let attachmentGeneration: UInt64
    public let expectedStateRevision: UInt64
    public let maxLines: Int
    public let maxBytes: Int

    public init(
        target: PersistentTerminalInteractionTarget,
        attachmentGeneration: UInt64,
        expectedStateRevision: UInt64,
        maxLines: Int,
        maxBytes: Int
    ) throws {
        guard (1...Self.maximumLines).contains(maxLines) else {
            throw PersistentTerminalInteractionError.invalidHistoryLineLimit(maxLines)
        }
        guard (1...Self.maximumBytes).contains(maxBytes) else {
            throw PersistentTerminalInteractionError.invalidHistoryByteLimit(maxBytes)
        }
        self.target = target
        self.attachmentGeneration = attachmentGeneration
        self.expectedStateRevision = expectedStateRevision
        self.maxLines = maxLines
        self.maxBytes = maxBytes
    }
}

public struct PersistentTerminalHistoryLine: Sendable, Equatable {
    public let text: String
    public let cellColumnToUTF16Offset: [Int]
    public let isWrapped: Bool

    public init(text: String, cellColumnToUTF16Offset: [Int], isWrapped: Bool) {
        self.text = text
        self.cellColumnToUTF16Offset = cellColumnToUTF16Offset
        self.isWrapped = isWrapped
    }
}

public struct PersistentTerminalHistorySnapshot: Sendable, Equatable {
    public let target: PersistentTerminalInteractionTarget
    public let attachmentGeneration: UInt64
    public let stateRevision: UInt64
    public let capturedAt: Date
    public let lines: [PersistentTerminalHistoryLine]
    public let visibleLineRange: Range<Int>
    public let isTruncated: Bool
    public let byteCount: Int

    public init(
        target: PersistentTerminalInteractionTarget,
        attachmentGeneration: UInt64,
        stateRevision: UInt64,
        capturedAt: Date,
        lines: [PersistentTerminalHistoryLine],
        visibleLineRange: Range<Int>,
        isTruncated: Bool,
        byteCount: Int
    ) {
        self.target = target
        self.attachmentGeneration = attachmentGeneration
        self.stateRevision = stateRevision
        self.capturedAt = capturedAt
        self.lines = lines
        self.visibleLineRange = visibleLineRange
        self.isTruncated = isTruncated
        self.byteCount = byteCount
    }
}

public enum PersistentTerminalScrollDirection: Sendable, Equatable {
    case up
    case down
}

public struct PersistentTerminalModeScrollRequest: Sendable, Equatable {
    public static let maximumRows = 64

    public let target: PersistentTerminalInteractionTarget
    public let attachmentGeneration: UInt64
    public let expectedStateRevision: UInt64
    public let direction: PersistentTerminalScrollDirection
    public let rows: Int

    public init(
        target: PersistentTerminalInteractionTarget,
        attachmentGeneration: UInt64,
        expectedStateRevision: UInt64,
        direction: PersistentTerminalScrollDirection,
        rows: Int
    ) throws {
        guard (1...Self.maximumRows).contains(rows) else {
            throw PersistentTerminalInteractionError.invalidScrollRows(rows)
        }
        self.target = target
        self.attachmentGeneration = attachmentGeneration
        self.expectedStateRevision = expectedStateRevision
        self.direction = direction
        self.rows = rows
    }
}

public protocol PersistentTerminalInteractiveAttachment: PersistentTerminalAttachment {
    var interaction: any PersistentTerminalInteractionFacet { get }
}

public protocol PersistentTerminalInteractionFacet: AnyObject, Sendable {
    var states: AsyncStream<PersistentTerminalInteractionState> { get }
    func resolveState() async throws -> PersistentTerminalInteractionState
    func captureHistory(
        _ request: PersistentTerminalHistoryRequest
    ) async throws -> PersistentTerminalHistorySnapshot
    func scrollProviderMode(_ request: PersistentTerminalModeScrollRequest) async throws
}

/// Shared bounded stream construction prevents slow UI consumers from retaining
/// unbounded provider snapshots. Interaction state is replaceable, not an event log.
public enum PersistentTerminalInteractionStreams {
    public static func makeStateStream(
        bufferingNewest limit: Int = 1
    ) -> (
        stream: AsyncStream<PersistentTerminalInteractionState>,
        continuation: AsyncStream<PersistentTerminalInteractionState>.Continuation
    ) {
        AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(max(limit, 1)))
    }
}
