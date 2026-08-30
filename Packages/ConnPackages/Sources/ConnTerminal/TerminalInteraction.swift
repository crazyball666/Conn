import ConnMultiplexer

public enum TerminalMouseTracking: Sendable, Equatable {
    case off
    case pressOnly
    case pressAndRelease
    case buttonMotion
    case allMotion

    public var reportsMouse: Bool { self != .off }
}

public struct TerminalProtocolState: Sendable, Equatable {
    public let revision: UInt64
    public let isAlternateBuffer: Bool
    public let mouseTracking: TerminalMouseTracking
    public let alternateScrollEnabled: Bool
    public let bracketedPasteEnabled: Bool
    public let focusReportingEnabled: Bool
    public let synchronizedOutputEnabled: Bool
    public let applicationCursorEnabled: Bool
    public let columns: Int
    public let rows: Int

    public init(
        revision: UInt64,
        isAlternateBuffer: Bool,
        mouseTracking: TerminalMouseTracking,
        alternateScrollEnabled: Bool = true,
        bracketedPasteEnabled: Bool,
        focusReportingEnabled: Bool,
        synchronizedOutputEnabled: Bool = false,
        applicationCursorEnabled: Bool,
        columns: Int,
        rows: Int
    ) {
        self.revision = revision
        self.isAlternateBuffer = isAlternateBuffer
        self.mouseTracking = mouseTracking
        self.alternateScrollEnabled = alternateScrollEnabled
        self.bracketedPasteEnabled = bracketedPasteEnabled
        self.focusReportingEnabled = focusReportingEnabled
        self.synchronizedOutputEnabled = synchronizedOutputEnabled
        self.applicationCursorEnabled = applicationCursorEnabled
        self.columns = columns
        self.rows = rows
    }
}

public struct TerminalHostScrollSignature: Sendable, Equatable {
    public let isAlternateBuffer: Bool
    public let mouseTracking: TerminalMouseTracking
    public let alternateScrollEnabled: Bool
    public let columns: Int
    public let rows: Int

    public init(_ state: TerminalProtocolState) {
        isAlternateBuffer = state.isAlternateBuffer
        mouseTracking = state.mouseTracking
        alternateScrollEnabled = state.alternateScrollEnabled
        columns = state.columns
        rows = state.rows
    }
}

public struct TerminalPersistentScrollSignature: Sendable, Equatable {
    public let freshness: TerminalPersistentStateFreshness
    public let isAlternateBuffer: Bool
    public let modeCapability: TerminalPersistentModeCapability
    public let historyOwnership: PersistentTerminalHistoryOwnership
    public let historyAvailable: Bool
    public let targetID: String?

    public init(_ state: TerminalPersistentRouteState) {
        freshness = state.freshness
        isAlternateBuffer = state.isAlternateBuffer
        modeCapability = state.modeCapability
        historyOwnership = state.historyOwnership
        historyAvailable = state.historyAvailable
        targetID = state.targetID
    }
}

public enum TerminalInteractionMode: Sendable, Equatable {
    case live
    case review
    case selecting
    case pointer
}

public enum TerminalPersistentStateFreshness: Sendable, Equatable {
    case fresh
    case stale
}

public enum TerminalPersistentModeCapability: Sendable, Equatable {
    case none
    case scrollable
    case keyDriven
    case unsupported
}

public struct TerminalPersistentRouteState: Sendable, Equatable {
    public let revision: UInt64
    public let freshness: TerminalPersistentStateFreshness
    public let isAlternateBuffer: Bool
    public let modeCapability: TerminalPersistentModeCapability
    public let historyOwnership: PersistentTerminalHistoryOwnership
    public let historyAvailable: Bool
    public let targetID: String?

    public init(
        revision: UInt64,
        freshness: TerminalPersistentStateFreshness,
        isAlternateBuffer: Bool,
        modeCapability: TerminalPersistentModeCapability,
        historyOwnership: PersistentTerminalHistoryOwnership = .local,
        historyAvailable: Bool,
        targetID: String? = nil
    ) {
        self.revision = revision
        self.freshness = freshness
        self.isAlternateBuffer = isAlternateBuffer
        self.modeCapability = modeCapability
        self.historyOwnership = historyOwnership
        self.historyAvailable = historyAvailable
        self.targetID = targetID
    }
}

public struct TerminalScrollRouteInput: Sendable, Equatable {
    public let mode: TerminalInteractionMode
    public let protocolState: TerminalProtocolState
    public let terminalGeneration: UInt64
    public let attachmentGeneration: UInt64
    public let persistent: TerminalPersistentRouteState?
    public let localHistoryAvailable: Bool

    public init(
        mode: TerminalInteractionMode,
        protocolState: TerminalProtocolState,
        terminalGeneration: UInt64,
        attachmentGeneration: UInt64,
        persistent: TerminalPersistentRouteState?,
        localHistoryAvailable: Bool
    ) {
        self.mode = mode
        self.protocolState = protocolState
        self.terminalGeneration = terminalGeneration
        self.attachmentGeneration = attachmentGeneration
        self.persistent = persistent
        self.localHistoryAvailable = localHistoryAvailable
    }
}

public struct TerminalRouteToken: Sendable, Equatable {
    public let terminalGeneration: UInt64
    public let attachmentGeneration: UInt64
    public let host: TerminalHostScrollSignature
    public let persistent: TerminalPersistentScrollSignature?

    public init(_ input: TerminalScrollRouteInput) {
        terminalGeneration = input.terminalGeneration
        attachmentGeneration = input.attachmentGeneration
        host = TerminalHostScrollSignature(input.protocolState)
        persistent = input.persistent.map(TerminalPersistentScrollSignature.init)
    }

    public func matches(_ input: TerminalScrollRouteInput) -> Bool {
        terminalGeneration == input.terminalGeneration
            && attachmentGeneration == input.attachmentGeneration
            && host == TerminalHostScrollSignature(input.protocolState)
            && persistent == input.persistent.map(TerminalPersistentScrollSignature.init)
    }
}

public enum TerminalScrollActionKind: Sendable, Equatable {
    case selection
    case pointer
    case remoteMouse
    case providerScrollableMode
    case providerKeyDrivenMode
    case providerUnsupportedBoundary
    case providerAlternateKeys
    case providerHistory
    case plainAlternateKeys
    case localNormalBuffer
    case resolvePersistentState
    case boundary
}

public enum TerminalScrollTransport: Sendable, Equatable {
    case none
    case remoteMouse
    case terminalCursorKeys
    case terminalScrollKeys
    case providerControl
    case resolvePersistentState
}

public enum TerminalScrollAction: Sendable, Equatable {
    case selection
    case pointer
    case remoteMouse(TerminalRouteToken)
    case providerScrollableMode(TerminalRouteToken)
    case providerKeyDrivenMode(TerminalRouteToken)
    case providerUnsupportedBoundary(TerminalRouteToken)
    case providerAlternateKeys(TerminalRouteToken)
    case providerHistory(TerminalRouteToken)
    case plainAlternateKeys(TerminalRouteToken)
    case localNormalBuffer(TerminalRouteToken)
    case resolvePersistentState(TerminalRouteToken)
    case boundary(TerminalRouteToken)

    public var kind: TerminalScrollActionKind {
        switch self {
        case .selection: .selection
        case .pointer: .pointer
        case .remoteMouse: .remoteMouse
        case .providerScrollableMode: .providerScrollableMode
        case .providerKeyDrivenMode: .providerKeyDrivenMode
        case .providerUnsupportedBoundary: .providerUnsupportedBoundary
        case .providerAlternateKeys: .providerAlternateKeys
        case .providerHistory: .providerHistory
        case .plainAlternateKeys: .plainAlternateKeys
        case .localNormalBuffer: .localNormalBuffer
        case .resolvePersistentState: .resolvePersistentState
        case .boundary: .boundary
        }
    }

    public var token: TerminalRouteToken? {
        switch self {
        case .selection, .pointer:
            nil
        case let .remoteMouse(token),
             let .providerScrollableMode(token),
             let .providerKeyDrivenMode(token),
             let .providerUnsupportedBoundary(token),
             let .providerAlternateKeys(token),
             let .providerHistory(token),
             let .plainAlternateKeys(token),
             let .localNormalBuffer(token),
             let .resolvePersistentState(token),
             let .boundary(token):
            token
        }
    }

    /// High-frequency scrolling stays on the terminal data channel once the remote
    /// provider is already in an interactive mode. Provider control is reserved for
    /// the one transition from live output into provider-owned history.
    public var transport: TerminalScrollTransport {
        switch self {
        case .remoteMouse:
            .remoteMouse
        case .providerScrollableMode:
            .terminalScrollKeys
        case .providerKeyDrivenMode, .providerAlternateKeys, .plainAlternateKeys:
            .terminalCursorKeys
        case .providerHistory:
            .providerControl
        case .resolvePersistentState:
            .resolvePersistentState
        case .selection, .pointer, .providerUnsupportedBoundary,
             .localNormalBuffer, .boundary:
            .none
        }
    }

    public var isRemoteScroll: Bool {
        switch self {
        case .remoteMouse, .providerScrollableMode, .providerKeyDrivenMode,
             .providerAlternateKeys, .providerHistory, .plainAlternateKeys,
             .resolvePersistentState:
            true
        case .selection, .pointer, .providerUnsupportedBoundary,
             .localNormalBuffer, .boundary:
            false
        }
    }
}

public struct TerminalScrollRouter: Sendable {
    public init() {}

    public func route(_ input: TerminalScrollRouteInput) -> TerminalScrollAction {
        if input.mode == .selecting || input.mode == .review {
            return .selection
        }
        if input.mode == .pointer {
            return .pointer
        }

        let token = TerminalRouteToken(input)
        if input.protocolState.mouseTracking.reportsMouse {
            return .remoteMouse(token)
        }

        if let persistent = input.persistent {
            guard persistent.freshness == .fresh else {
                return .resolvePersistentState(token)
            }
            switch persistent.modeCapability {
            case .scrollable:
                return .providerScrollableMode(token)
            case .keyDriven:
                return .providerKeyDrivenMode(token)
            case .unsupported:
                return .providerUnsupportedBoundary(token)
            case .none:
                break
            }
            if persistent.isAlternateBuffer {
                return .providerAlternateKeys(token)
            }
            if persistent.historyOwnership == .provider {
                return persistent.historyAvailable
                    ? .providerHistory(token)
                    : .resolvePersistentState(token)
            }
            return .boundary(token)
        }

        if input.protocolState.isAlternateBuffer,
           input.protocolState.alternateScrollEnabled {
            return .plainAlternateKeys(token)
        }
        if input.localHistoryAvailable {
            return .localNormalBuffer(token)
        }
        return .boundary(token)
    }
}
