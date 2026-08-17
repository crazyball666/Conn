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
    case unsupportedQuickAction(String)
    case invalidQuickActionRepeatCount(Int)
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

/// Provider-owned actions that can be performed against the currently attached terminal.
///
/// The terminal UI renders these descriptors without knowing whether the provider is tmux,
/// Zellij, Screen, or a future implementation. `titleKey` is localized by the presentation
/// layer while `systemImageName` is optional presentation metadata, not executable syntax.
public struct PersistentTerminalQuickActionDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let titleKey: String
    public let systemImageName: String
    public let textInput: PersistentTerminalQuickActionTextInput?

    public init(
        id: String,
        titleKey: String,
        systemImageName: String,
        textInput: PersistentTerminalQuickActionTextInput? = nil
    ) {
        self.id = id
        self.titleKey = titleKey
        self.systemImageName = systemImageName
        self.textInput = textInput
    }
}

public struct PersistentTerminalQuickActionTextInput: Sendable, Equatable {
    public let titleKey: String
    public let placeholderKey: String

    public init(titleKey: String, placeholderKey: String) {
        self.titleKey = titleKey
        self.placeholderKey = placeholderKey
    }
}

public struct PersistentTerminalQuickActionSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let titleKey: String
    public let actions: [PersistentTerminalQuickActionDescriptor]

    public init(
        id: String,
        titleKey: String,
        actions: [PersistentTerminalQuickActionDescriptor]
    ) {
        self.id = id
        self.titleKey = titleKey
        self.actions = actions
    }
}

/// Optional direct-touch navigation supplied by a persistent-terminal provider.
///
/// The host owns gesture recognition while the provider owns direction-to-action semantics.
/// This keeps tmux Window IDs and commands out of the terminal renderer and lets a future
/// provider map the same gesture to its own tab/workspace model.
public enum PersistentTerminalHorizontalSwipeDirection: String, Sendable, Equatable {
    case left
    case right
}

public struct PersistentTerminalSwipeActionDescriptor: Sendable, Equatable, Identifiable {
    public var id: String { direction.rawValue }

    public let direction: PersistentTerminalHorizontalSwipeDirection
    public let actionID: String
    public let successNoticeKey: String

    public init(
        direction: PersistentTerminalHorizontalSwipeDirection,
        actionID: String,
        successNoticeKey: String
    ) {
        self.direction = direction
        self.actionID = actionID
        self.successNoticeKey = successNoticeKey
    }
}

public struct PersistentTerminalQuickActionGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let sections: [PersistentTerminalQuickActionSection]
    public let swipeActions: [PersistentTerminalSwipeActionDescriptor]

    public var actions: [PersistentTerminalQuickActionDescriptor] {
        sections.flatMap(\.actions)
    }

    public init(
        id: String,
        title: String,
        sections: [PersistentTerminalQuickActionSection],
        swipeActions: [PersistentTerminalSwipeActionDescriptor] = []
    ) {
        self.id = id
        self.title = title
        self.sections = sections
        self.swipeActions = swipeActions
    }

    public func swipeAction(
        for direction: PersistentTerminalHorizontalSwipeDirection
    ) -> PersistentTerminalSwipeActionDescriptor? {
        swipeActions.first { $0.direction == direction }
    }
}

/// Pins a provider action to the exact attachment, target, and observed state that supplied
/// its UI. Providers must reject stale requests instead of applying an action to a different
/// Pane or workspace after an asynchronous topology change.
public struct PersistentTerminalQuickActionRequest: Sendable, Equatable {
    public static let maximumRepeatCount = 32

    public let actionID: String
    public let target: PersistentTerminalInteractionTarget
    public let attachmentGeneration: UInt64
    public let expectedStateRevision: UInt64
    public let argument: String?
    /// 连续同类高频动作的合并次数。普通按钮保持 1；provider 决定哪些动作允许大于 1。
    public let repeatCount: Int

    public init(
        actionID: String,
        target: PersistentTerminalInteractionTarget,
        attachmentGeneration: UInt64,
        expectedStateRevision: UInt64,
        argument: String? = nil,
        repeatCount: Int = 1
    ) {
        self.actionID = actionID
        self.target = target
        self.attachmentGeneration = attachmentGeneration
        self.expectedStateRevision = expectedStateRevision
        self.argument = argument
        self.repeatCount = repeatCount
    }
}

public protocol PersistentTerminalInteractiveAttachment: PersistentTerminalAttachment {
    var interaction: any PersistentTerminalInteractionFacet { get }
}

public protocol PersistentTerminalInteractionFacet: AnyObject, Sendable {
    var states: AsyncStream<PersistentTerminalInteractionState> { get }
    var quickActionGroup: PersistentTerminalQuickActionGroup? { get async }
    func resolveState() async throws -> PersistentTerminalInteractionState
    func captureHistory(
        _ request: PersistentTerminalHistoryRequest
    ) async throws -> PersistentTerminalHistorySnapshot
    func scrollProviderMode(_ request: PersistentTerminalModeScrollRequest) async throws
    func performQuickAction(_ request: PersistentTerminalQuickActionRequest) async throws
}

/// Interaction facets are independently optional. A provider can support state/history while
/// omitting quick actions, and existing providers do not need no-op implementations.
public extension PersistentTerminalInteractionFacet {
    var quickActionGroup: PersistentTerminalQuickActionGroup? { get async { nil } }

    func performQuickAction(_ request: PersistentTerminalQuickActionRequest) async throws {
        throw PersistentTerminalInteractionError.unsupportedQuickAction(request.actionID)
    }
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
