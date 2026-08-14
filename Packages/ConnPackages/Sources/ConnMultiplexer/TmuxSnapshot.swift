import ConnSSH
import Foundation

public enum TmuxSnapshotValidationError: Error, Sendable, Equatable {
    case sessionKeyMismatch(key: TmuxSessionID, value: TmuxSessionID)
    case windowKeyMismatch(key: TmuxWindowID, value: TmuxWindowID)
    case paneKeyMismatch(key: TmuxPaneID, value: TmuxPaneID)
    case clientKeyMismatch(key: TmuxClientID, value: TmuxClientID)
    case missingLinkedSession(TmuxSessionID)
    case missingLinkedWindow(TmuxWindowID)
    case invalidWindowLinkIndex(sessionID: TmuxSessionID, index: Int)
    case duplicateWindowLink(sessionID: TmuxSessionID, windowID: TmuxWindowID, index: Int)
    case duplicateWindowIndex(sessionID: TmuxSessionID, index: Int)
    case missingCurrentWindow(sessionID: TmuxSessionID, windowID: TmuxWindowID)
    case currentWindowNotLinked(sessionID: TmuxSessionID, windowID: TmuxWindowID)
    case missingPaneWindow(paneID: TmuxPaneID, windowID: TmuxWindowID)
    case invalidPaneSize(TmuxPaneID)
    case duplicatePaneIndex(windowID: TmuxWindowID, index: Int)
    case missingActivePane(windowID: TmuxWindowID, paneID: TmuxPaneID)
    case activePaneWindowMismatch(windowID: TmuxWindowID, paneID: TmuxPaneID)
    case missingGroupSession(groupName: String, sessionID: TmuxSessionID)
    case groupMembershipMismatch(groupName: String, sessionID: TmuxSessionID)
    case missingClientSession(clientID: TmuxClientID, sessionID: TmuxSessionID)
    case clientCurrentWindowNotLinked(clientID: TmuxClientID, windowID: TmuxWindowID)
    case missingClientActivePane(clientID: TmuxClientID, paneID: TmuxPaneID)
    case clientActivePaneWindowMismatch(clientID: TmuxClientID, paneID: TmuxPaneID)
    case controlClientSessionMismatch(clientID: TmuxClientID)
    case controlClientKindMismatch(TmuxClientID)
    case controlClientMayParticipateInSize(TmuxClientID)
    case impactRevisionExceedsRevision
}

public struct TmuxServerInstance: Sendable, Equatable {
    public let token: TmuxServerInstanceToken
    public let version: String?

    public init(token: TmuxServerInstanceToken, version: String?) {
        self.token = token
        self.version = version
    }
}

public struct TmuxSessionSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxSessionID
    public let name: String
    public let groupName: String?
    public let currentWindowID: TmuxWindowID?

    public init(
        id: TmuxSessionID,
        name: String,
        groupName: String?,
        currentWindowID: TmuxWindowID?
    ) {
        self.id = id
        self.name = name
        self.groupName = groupName
        self.currentWindowID = currentWindowID
    }
}

public struct TmuxWindowSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxWindowID
    public let name: String
    public let layout: String?
    public let isZoomed: Bool
    public let activePaneID: TmuxPaneID?

    public init(
        id: TmuxWindowID,
        name: String,
        layout: String?,
        isZoomed: Bool,
        activePaneID: TmuxPaneID?
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.isZoomed = isZoomed
        self.activePaneID = activePaneID
    }
}

public struct TmuxPaneSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxPaneID
    public let windowID: TmuxWindowID
    public let index: Int
    public let title: TmuxObservedValue<String>
    public let currentCommand: TmuxObservedValue<String>
    public let currentPath: TmuxObservedValue<String>
    public let size: TermSize
    public let isDead: Bool

    public init(
        id: TmuxPaneID,
        windowID: TmuxWindowID,
        index: Int,
        title: TmuxObservedValue<String>,
        currentCommand: TmuxObservedValue<String>,
        currentPath: TmuxObservedValue<String>,
        size: TermSize,
        isDead: Bool
    ) {
        self.id = id
        self.windowID = windowID
        self.index = index
        self.title = title
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.size = size
        self.isDead = isDead
    }
}

public struct TmuxObservedValue<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value?
    public let freshness: TmuxMetadataFreshness

    public init(value: Value?, freshness: TmuxMetadataFreshness) {
        self.value = value
        self.freshness = freshness
    }

    public static var unavailable: Self {
        Self(value: nil, freshness: .unavailable)
    }
}

public struct TmuxWindowLink: Sendable, Equatable, Hashable {
    public let sessionID: TmuxSessionID
    public let windowID: TmuxWindowID
    public let index: Int

    public init(sessionID: TmuxSessionID, windowID: TmuxWindowID, index: Int) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.index = index
    }
}

public struct TmuxClientID: Sendable, Equatable, Hashable {
    public let targetName: String
    public let processID: Int32?
    public let createdAt: Int64?

    public init(targetName: String, processID: Int32?, createdAt: Int64?) {
        self.targetName = targetName
        self.processID = processID
        self.createdAt = createdAt
    }
}

public struct TmuxClientSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxClientID
    /// The tty is the transport-level half of Conn's ownership proof. It is optional
    /// because older tmux versions may not expose a stable client tty field.
    public let tty: String?
    public let sessionID: TmuxSessionID
    public let currentWindowID: TmuxWindowID?
    public let activePaneID: TmuxPaneID?
    public let flags: Set<TmuxClientFlag>?
    public let role: TmuxClientRole
    public let kind: TmuxClientKind
    public let sizeParticipation: TmuxClientSizeParticipation
    public let observedAt: Date

    public init(
        id: TmuxClientID,
        sessionID: TmuxSessionID,
        currentWindowID: TmuxWindowID?,
        activePaneID: TmuxPaneID?,
        flags: Set<TmuxClientFlag>?,
        role: TmuxClientRole,
        kind: TmuxClientKind,
        sizeParticipation: TmuxClientSizeParticipation,
        observedAt: Date,
        tty: String? = nil
    ) {
        self.id = id
        self.tty = tty
        self.sessionID = sessionID
        self.currentWindowID = currentWindowID
        self.activePaneID = activePaneID
        self.flags = flags
        self.role = role
        self.kind = kind
        self.sizeParticipation = sizeParticipation
        self.observedAt = observedAt
    }
}

public enum TmuxClientRole: Sendable, Equatable {
    case connInteractive(attachmentID: String)
    case connControl(sessionID: TmuxSessionID)
    case external
}

public enum TmuxClientKind: Sendable, Equatable {
    case interactiveTerminal
    case controlMode
    case unknown
}

public enum TmuxClientSizeParticipation: Sendable, Equatable {
    case participating
    case ignored
    case notParticipating
    case unknown
}

public enum TmuxMetadataFreshness: Sendable, Equatable {
    case liveSubscription(observedAt: Date)
    case snapshot(observedAt: Date)
    case stale(lastObservedAt: Date?)
    case unavailable
}

public struct TmuxServerSnapshot: Sendable, Equatable {
    public let instance: TmuxServerInstance
    public let sessions: [TmuxSessionID: TmuxSessionSnapshot]
    public let sessionGroups: [String: Set<TmuxSessionID>]
    public let windows: [TmuxWindowID: TmuxWindowSnapshot]
    public let panes: [TmuxPaneID: TmuxPaneSnapshot]
    public let windowLinks: [TmuxWindowLink]
    public let clients: [TmuxClientID: TmuxClientSnapshot]
    public let observedAt: Date
    public let revision: UInt64
    public let impactRevision: UInt64

    public init(
        instance: TmuxServerInstance,
        sessions: [TmuxSessionID: TmuxSessionSnapshot],
        sessionGroups: [String: Set<TmuxSessionID>],
        windows: [TmuxWindowID: TmuxWindowSnapshot],
        panes: [TmuxPaneID: TmuxPaneSnapshot],
        windowLinks: [TmuxWindowLink],
        clients: [TmuxClientID: TmuxClientSnapshot],
        observedAt: Date,
        revision: UInt64,
        impactRevision: UInt64
    ) throws {
        self.instance = instance
        self.sessions = sessions
        self.sessionGroups = sessionGroups
        self.windows = windows
        self.panes = panes
        self.windowLinks = windowLinks
        self.clients = clients
        self.observedAt = observedAt
        self.revision = revision
        self.impactRevision = impactRevision
        try validate()
    }

    public func windows(in sessionID: TmuxSessionID) -> [TmuxWindowID] {
        windowLinks
            .filter { $0.sessionID == sessionID }
            .sorted { lhs, rhs in
                lhs.index == rhs.index
                    ? lhs.windowID.rawValue < rhs.windowID.rawValue
                    : lhs.index < rhs.index
            }
            .map(\.windowID)
    }

    public func panes(in windowID: TmuxWindowID) -> [TmuxPaneID] {
        panes.values
            .filter { $0.windowID == windowID }
            .sorted { lhs, rhs in
                lhs.index == rhs.index
                    ? lhs.id.rawValue < rhs.id.rawValue
                    : lhs.index < rhs.index
            }
            .map(\.id)
    }

    public func externalAttachedClientCount(in sessionID: TmuxSessionID? = nil) -> Int {
        matchingClients(in: sessionID).count { $0.role == .external }
    }

    public func affectedAttachedClientCount(in sessionID: TmuxSessionID? = nil) -> Int {
        matchingClients(in: sessionID).count { !$0.role.isConnControl }
    }

    public func interactiveClientCount(in sessionID: TmuxSessionID? = nil) -> Int {
        matchingClients(in: sessionID).count { client in
            !client.role.isConnControl && client.kind.isInteractiveOrUnknown
        }
    }

    public func sizeParticipatingClientCount(in sessionID: TmuxSessionID? = nil) -> Int {
        matchingClients(in: sessionID).count { client in
            client.sizeParticipation == .participating || client.sizeParticipation == .unknown
        }
    }

    public func otherAffectedClientCount(
        in sessionID: TmuxSessionID,
        relativeToAttachmentID attachmentID: String
    ) -> Int {
        matchingClients(in: sessionID).count { client in
            switch client.role {
            case .connControl:
                false
            case let .connInteractive(candidate):
                candidate != attachmentID
            case .external:
                true
            }
        }
    }

    public func otherInteractiveClientCount(
        in sessionID: TmuxSessionID,
        relativeToAttachmentID attachmentID: String
    ) -> Int {
        matchingClients(in: sessionID).count { client in
            guard client.kind.isInteractiveOrUnknown else { return false }
            switch client.role {
            case .connControl:
                return false
            case let .connInteractive(candidate):
                return candidate != attachmentID
            case .external:
                return true
            }
        }
    }

    private func matchingClients(in sessionID: TmuxSessionID?) -> [TmuxClientSnapshot] {
        clients.values.filter { sessionID == nil || $0.sessionID == sessionID }
    }

    private func validate() throws {
        guard impactRevision <= revision else {
            throw TmuxSnapshotValidationError.impactRevisionExceedsRevision
        }
        for (key, session) in sessions where key != session.id {
            throw TmuxSnapshotValidationError.sessionKeyMismatch(key: key, value: session.id)
        }
        for (key, window) in windows where key != window.id {
            throw TmuxSnapshotValidationError.windowKeyMismatch(key: key, value: window.id)
        }
        for (key, pane) in panes where key != pane.id {
            throw TmuxSnapshotValidationError.paneKeyMismatch(key: key, value: pane.id)
        }
        for (key, client) in clients where key != client.id {
            throw TmuxSnapshotValidationError.clientKeyMismatch(key: key, value: client.id)
        }

        var seenLinks: Set<TmuxWindowLink> = []
        var seenIndexes: Set<TmuxSessionWindowIndex> = []
        for link in windowLinks {
            guard link.index >= 0 else {
                throw TmuxSnapshotValidationError.invalidWindowLinkIndex(
                    sessionID: link.sessionID,
                    index: link.index
                )
            }
            guard sessions[link.sessionID] != nil else {
                throw TmuxSnapshotValidationError.missingLinkedSession(link.sessionID)
            }
            guard windows[link.windowID] != nil else {
                throw TmuxSnapshotValidationError.missingLinkedWindow(link.windowID)
            }
            guard seenLinks.insert(link).inserted else {
                throw TmuxSnapshotValidationError.duplicateWindowLink(
                    sessionID: link.sessionID,
                    windowID: link.windowID,
                    index: link.index
                )
            }
            let indexedLink = TmuxSessionWindowIndex(sessionID: link.sessionID, index: link.index)
            guard seenIndexes.insert(indexedLink).inserted else {
                throw TmuxSnapshotValidationError.duplicateWindowIndex(
                    sessionID: link.sessionID,
                    index: link.index
                )
            }
        }

        var seenPaneIndexes: Set<TmuxWindowPaneIndex> = []
        for pane in panes.values {
            guard windows[pane.windowID] != nil else {
                throw TmuxSnapshotValidationError.missingPaneWindow(
                    paneID: pane.id,
                    windowID: pane.windowID
                )
            }
            guard pane.index >= 0, pane.size.cols > 0, pane.size.rows > 0 else {
                throw TmuxSnapshotValidationError.invalidPaneSize(pane.id)
            }
            let indexedPane = TmuxWindowPaneIndex(windowID: pane.windowID, index: pane.index)
            guard seenPaneIndexes.insert(indexedPane).inserted else {
                throw TmuxSnapshotValidationError.duplicatePaneIndex(
                    windowID: pane.windowID,
                    index: pane.index
                )
            }
        }

        for session in sessions.values {
            if let currentWindowID = session.currentWindowID {
                guard windows[currentWindowID] != nil else {
                    throw TmuxSnapshotValidationError.missingCurrentWindow(
                        sessionID: session.id,
                        windowID: currentWindowID
                    )
                }
                guard windowLinks.contains(where: {
                    $0.sessionID == session.id && $0.windowID == currentWindowID
                }) else {
                    throw TmuxSnapshotValidationError.currentWindowNotLinked(
                        sessionID: session.id,
                        windowID: currentWindowID
                    )
                }
            }
        }

        for window in windows.values {
            if let activePaneID = window.activePaneID {
                guard let activePane = panes[activePaneID] else {
                    throw TmuxSnapshotValidationError.missingActivePane(
                        windowID: window.id,
                        paneID: activePaneID
                    )
                }
                guard activePane.windowID == window.id else {
                    throw TmuxSnapshotValidationError.activePaneWindowMismatch(
                        windowID: window.id,
                        paneID: activePaneID
                    )
                }
            }
        }

        try validateGroups()
        try validateClients()
    }

    private func validateGroups() throws {
        for (groupName, members) in sessionGroups {
            for sessionID in members {
                guard let session = sessions[sessionID] else {
                    throw TmuxSnapshotValidationError.missingGroupSession(
                        groupName: groupName,
                        sessionID: sessionID
                    )
                }
                guard session.groupName == groupName else {
                    throw TmuxSnapshotValidationError.groupMembershipMismatch(
                        groupName: groupName,
                        sessionID: sessionID
                    )
                }
            }
        }
        for session in sessions.values {
            if let groupName = session.groupName,
               sessionGroups[groupName]?.contains(session.id) != true
            {
                throw TmuxSnapshotValidationError.groupMembershipMismatch(
                    groupName: groupName,
                    sessionID: session.id
                )
            }
        }
    }

    private func validateClients() throws {
        for client in clients.values {
            guard sessions[client.sessionID] != nil else {
                throw TmuxSnapshotValidationError.missingClientSession(
                    clientID: client.id,
                    sessionID: client.sessionID
                )
            }
            if let currentWindowID = client.currentWindowID {
                guard windows[currentWindowID] != nil,
                      windowLinks.contains(where: {
                          $0.sessionID == client.sessionID && $0.windowID == currentWindowID
                      })
                else {
                    throw TmuxSnapshotValidationError.clientCurrentWindowNotLinked(
                        clientID: client.id,
                        windowID: currentWindowID
                    )
                }
            }
            if let activePaneID = client.activePaneID {
                guard let activePane = panes[activePaneID] else {
                    throw TmuxSnapshotValidationError.missingClientActivePane(
                        clientID: client.id,
                        paneID: activePaneID
                    )
                }
                guard client.currentWindowID == activePane.windowID else {
                    throw TmuxSnapshotValidationError.clientActivePaneWindowMismatch(
                        clientID: client.id,
                        paneID: activePaneID
                    )
                }
            }
            if case let .connControl(sessionID) = client.role {
                guard sessionID == client.sessionID else {
                    throw TmuxSnapshotValidationError.controlClientSessionMismatch(clientID: client.id)
                }
                guard client.kind == .controlMode else {
                    throw TmuxSnapshotValidationError.controlClientKindMismatch(client.id)
                }
                guard client.sizeParticipation == .notParticipating else {
                    throw TmuxSnapshotValidationError.controlClientMayParticipateInSize(client.id)
                }
            }
        }
    }
}

private struct TmuxSessionWindowIndex: Hashable {
    let sessionID: TmuxSessionID
    let index: Int
}

private struct TmuxWindowPaneIndex: Hashable {
    let windowID: TmuxWindowID
    let index: Int
}

private extension TmuxClientRole {
    var isConnControl: Bool {
        if case .connControl = self { return true }
        return false
    }
}

private extension TmuxClientKind {
    var isInteractiveOrUnknown: Bool {
        self == .interactiveTerminal || self == .unknown
    }
}
