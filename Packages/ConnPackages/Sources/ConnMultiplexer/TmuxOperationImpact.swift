import Foundation

public enum TmuxOperationImpactError: Error, Sendable, Equatable {
    case missingSession(TmuxSessionID)
    case missingWindow(TmuxWindowID)
    case missingPane(TmuxPaneID)
    case missingClientTarget(TmuxClientTarget)
    case ambiguousClientTarget(TmuxClientTarget)
    case clientTargetNotConnInteractive(TmuxClientID)
    case clientTargetDoesNotMatchInitiatingAttachment(TmuxClientID)
    case clientNotAttachedToSession(clientID: TmuxClientID, sessionID: TmuxSessionID)
    case windowNotLinkedToClientSession(windowID: TmuxWindowID, clientID: TmuxClientID)
    case paneNotLinkedToClientSession(paneID: TmuxPaneID, clientID: TmuxClientID)
}

public enum TmuxPaneFocusIsolation: String, Sendable, Codable, Equatable {
    /// The Control Client could not enable `active-pane`; selecting a Pane changes Window state.
    case sharedWindow
    /// The verified interactive client has an enabled `active-pane` flag.
    case clientLocal
}

public struct TmuxOperationImpactContext: Sendable, Equatable {
    public let initiatingAttachmentID: String?
    public let paneFocusIsolation: TmuxPaneFocusIsolation

    public init(
        initiatingAttachmentID: String? = nil,
        paneFocusIsolation: TmuxPaneFocusIsolation = .sharedWindow
    ) {
        self.initiatingAttachmentID = initiatingAttachmentID
        self.paneFocusIsolation = paneFocusIsolation
    }
}

public enum TmuxImpactEntityKind: String, Sendable, Codable, Equatable, Hashable {
    case session
    case window
    case pane
}

/// User-visible shared state changed by an operation. Product copy consumes these facts rather
/// than rediscovering tmux side effects independently in each screen.
public enum TmuxSharedStateEffect: String, Sendable, Codable, Equatable, Hashable {
    case sessionIdentity
    case sessionWindowSelection
    case sessionWindowTopology
    case windowIdentity
    case windowPaneSelection
    case clientPaneSelection
    case windowPaneTopology
    case windowPaneLayout
    case windowOption
    case windowZoom
    case clientAttachment
}

public enum TmuxOperationImpactTarget: Sendable, Equatable {
    case server
    case session(id: TmuxSessionID, name: String)
    case client(TmuxClientID)
    case window(id: TmuxWindowID, name: String)
    case pane(id: TmuxPaneID, index: Int, windowID: TmuxWindowID, windowName: String)
}

/// Deterministic projection of one operation against one validated normalized snapshot.
/// Arrays are unique and sorted by stable tmux identity so UI, confirmation, and tests observe
/// the same order regardless of Dictionary/Set iteration order.
public struct TmuxOperationImpact: Sendable, Equatable {
    public let semantics: TmuxOperationSemantics
    public let target: TmuxOperationImpactTarget
    public let createdEntityKinds: Set<TmuxImpactEntityKind>
    public let affectedSessionIDs: [TmuxSessionID]
    public let affectedWindowIDs: [TmuxWindowID]
    public let affectedPaneIDs: [TmuxPaneID]
    public let destroyedSessionIDs: [TmuxSessionID]
    public let destroyedWindowIDs: [TmuxWindowID]
    public let destroyedPaneIDs: [TmuxPaneID]
    public let removedWindowLinks: [TmuxWindowLink]
    public let otherAffectedClientIDs: [TmuxClientID]
    public let otherInteractiveClientIDs: [TmuxClientID]
    public let sharedStateEffects: Set<TmuxSharedStateEffect>

    public var isVisibleAcrossSessions: Bool {
        affectedSessionIDs.count > 1
    }

    package init(
        semantics: TmuxOperationSemantics,
        target: TmuxOperationImpactTarget,
        createdEntityKinds: Set<TmuxImpactEntityKind>,
        affectedSessionIDs: Set<TmuxSessionID>,
        affectedWindowIDs: Set<TmuxWindowID>,
        affectedPaneIDs: Set<TmuxPaneID>,
        destroyedSessionIDs: Set<TmuxSessionID>,
        destroyedWindowIDs: Set<TmuxWindowID>,
        destroyedPaneIDs: Set<TmuxPaneID>,
        removedWindowLinks: Set<TmuxWindowLink>,
        otherAffectedClientIDs: Set<TmuxClientID>,
        otherInteractiveClientIDs: Set<TmuxClientID>,
        sharedStateEffects: Set<TmuxSharedStateEffect>
    ) {
        self.semantics = semantics
        self.target = target
        self.createdEntityKinds = createdEntityKinds
        self.affectedSessionIDs = affectedSessionIDs.sorted(by: tmuxSessionOrder)
        self.affectedWindowIDs = affectedWindowIDs.sorted(by: tmuxWindowOrder)
        self.affectedPaneIDs = affectedPaneIDs.sorted(by: tmuxPaneOrder)
        self.destroyedSessionIDs = destroyedSessionIDs.sorted(by: tmuxSessionOrder)
        self.destroyedWindowIDs = destroyedWindowIDs.sorted(by: tmuxWindowOrder)
        self.destroyedPaneIDs = destroyedPaneIDs.sorted(by: tmuxPaneOrder)
        self.removedWindowLinks = removedWindowLinks.sorted(by: tmuxWindowLinkOrder)
        self.otherAffectedClientIDs = otherAffectedClientIDs.sorted(by: tmuxClientOrder)
        self.otherInteractiveClientIDs = otherInteractiveClientIDs.sorted(by: tmuxClientOrder)
        self.sharedStateEffects = sharedStateEffects
    }
}

public struct TmuxOperationImpactAnalyzer: Sendable {
    public init() {}

    public func analyze(
        _ operation: TmuxOperation,
        in snapshot: TmuxServerSnapshot,
        context: TmuxOperationImpactContext = .init()
    ) throws -> TmuxOperationImpact {
        var analysis = Analysis(semantics: operation.semantics)

        switch operation {
        case .createSession:
            analysis.target = .server
            analysis.createdEntityKinds = [.session]

        case let .renameSession(sessionID, _):
            let session = try requireSession(sessionID, in: snapshot)
            analysis.target = .session(id: session.id, name: session.name)
            analysis.affectedSessionIDs = [session.id]
            analysis.clientScope = .sessions([session.id])
            analysis.sharedStateEffects = [.sessionIdentity]

        case let .detachClient(target):
            let client = try requireOwnedInteractiveClient(
                target,
                in: snapshot,
                context: context
            )
            analysis.target = .client(client.id)
            analysis.affectedSessionIDs = [client.sessionID]
            analysis.clientScope = .clients([client.id])
            analysis.sharedStateEffects = [.clientAttachment]

        case let .killSession(sessionID):
            let session = try requireSession(sessionID, in: snapshot)
            let links = Set(snapshot.windowLinks.filter { $0.sessionID == sessionID })
            let windows = Set(links.map(\.windowID))
            let orphanedWindows = Set(windows.filter { windowID in
                !snapshot.windowLinks.contains {
                    $0.windowID == windowID && $0.sessionID != sessionID
                }
            })

            analysis.target = .session(id: session.id, name: session.name)
            analysis.affectedSessionIDs = [session.id]
            analysis.affectedWindowIDs = windows
            analysis.affectedPaneIDs = paneIDs(in: windows, snapshot: snapshot)
            analysis.destroyedSessionIDs = [session.id]
            analysis.destroyedWindowIDs = orphanedWindows
            analysis.destroyedPaneIDs = paneIDs(in: orphanedWindows, snapshot: snapshot)
            analysis.removedWindowLinks = links
            analysis.clientScope = .sessions([session.id])
            analysis.sharedStateEffects = [
                .clientAttachment,
                .sessionIdentity,
                .sessionWindowTopology,
            ]
            if !orphanedWindows.isEmpty {
                analysis.sharedStateEffects.insert(.windowPaneTopology)
            }

        case let .selectWindow(windowID, target):
            let window = try requireWindow(windowID, in: snapshot)
            let client = try requireOwnedInteractiveClient(
                target,
                in: snapshot,
                context: context
            )
            guard isLinked(windowID: windowID, to: client.sessionID, in: snapshot) else {
                throw TmuxOperationImpactError.windowNotLinkedToClientSession(
                    windowID: windowID,
                    clientID: client.id
                )
            }
            analysis.target = .window(id: window.id, name: window.name)
            analysis.affectedSessionIDs = [client.sessionID]
            analysis.affectedWindowIDs = [window.id]
            analysis.clientScope = .sessions([client.sessionID])
            analysis.sharedStateEffects = [.sessionWindowSelection]

        case let .selectRelativeWindow(sessionID, _, _, target):
            let session = try requireSession(sessionID, in: snapshot)
            let client = try requireOwnedInteractiveClient(
                target,
                in: snapshot,
                context: context
            )
            guard client.sessionID == sessionID else {
                throw TmuxOperationImpactError.clientNotAttachedToSession(
                    clientID: client.id,
                    sessionID: sessionID
                )
            }
            analysis.target = .session(id: session.id, name: session.name)
            analysis.affectedSessionIDs = [session.id]
            analysis.clientScope = .sessions([session.id])
            analysis.sharedStateEffects = [.sessionWindowSelection]

        case let .createWindow(sessionID, _):
            let session = try requireSession(sessionID, in: snapshot)
            let affectedSessions: Set<TmuxSessionID>
            if let groupName = session.groupName {
                affectedSessions = snapshot.sessionGroups[groupName] ?? [session.id]
            } else {
                affectedSessions = [session.id]
            }
            analysis.target = .session(id: session.id, name: session.name)
            analysis.createdEntityKinds = [.window]
            analysis.affectedSessionIDs = affectedSessions
            analysis.clientScope = .sessions(affectedSessions)
            analysis.sharedStateEffects = [.sessionWindowTopology]

        case let .renameWindow(windowID, _):
            let window = try requireWindow(windowID, in: snapshot)
            let sessions = sessionIDs(linkedTo: windowID, snapshot: snapshot)
            analysis.target = .window(id: window.id, name: window.name)
            analysis.affectedSessionIDs = sessions
            analysis.affectedWindowIDs = [window.id]
            analysis.clientScope = .sessions(sessions)
            analysis.sharedStateEffects = [.windowIdentity]

        case let .killWindow(windowID):
            let window = try requireWindow(windowID, in: snapshot)
            analyzeWindowDestruction(
                window: window,
                snapshot: snapshot,
                analysis: &analysis
            )

        case let .selectPane(paneID, target):
            let pane = try requirePane(paneID, in: snapshot)
            let window = try requireWindow(pane.windowID, in: snapshot)
            let client = try requireOwnedInteractiveClient(
                target,
                in: snapshot,
                context: context
            )
            guard isLinked(windowID: pane.windowID, to: client.sessionID, in: snapshot) else {
                throw TmuxOperationImpactError.paneNotLinkedToClientSession(
                    paneID: paneID,
                    clientID: client.id
                )
            }
            analysis.target = paneTarget(pane, window: window)
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = [pane.id]
            switch context.paneFocusIsolation {
            case .clientLocal:
                analysis.affectedSessionIDs = [client.sessionID]
                analysis.clientScope = .clients([client.id])
                analysis.sharedStateEffects = [.clientPaneSelection]
            case .sharedWindow:
                let sessions = sessionIDs(linkedTo: window.id, snapshot: snapshot)
                analysis.affectedSessionIDs = sessions
                analysis.clientScope = .sessions(sessions)
                analysis.sharedStateEffects = [.windowPaneSelection]
            }

        case let .splitPane(paneID, _):
            let pane = try requirePane(paneID, in: snapshot)
            let window = try requireWindow(pane.windowID, in: snapshot)
            let sessions = sessionIDs(linkedTo: window.id, snapshot: snapshot)
            analysis.target = paneTarget(pane, window: window)
            analysis.createdEntityKinds = [.pane]
            analysis.affectedSessionIDs = sessions
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = [pane.id]
            analysis.clientScope = .sessions(sessions)
            analysis.sharedStateEffects = [.windowPaneTopology]

        case let .applyPaneLayout(windowID, _), let .cyclePaneLayout(windowID):
            let window = try requireWindow(windowID, in: snapshot)
            let sessions = sessionIDs(linkedTo: window.id, snapshot: snapshot)
            analysis.target = .window(id: window.id, name: window.name)
            analysis.affectedSessionIDs = sessions
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = paneIDs(in: [window.id], snapshot: snapshot)
            analysis.clientScope = .sessions(sessions)
            analysis.sharedStateEffects = [.windowPaneLayout]

        case let .toggleSynchronizePanes(windowID):
            let window = try requireWindow(windowID, in: snapshot)
            let sessions = sessionIDs(linkedTo: window.id, snapshot: snapshot)
            analysis.target = .window(id: window.id, name: window.name)
            analysis.affectedSessionIDs = sessions
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = paneIDs(in: [window.id], snapshot: snapshot)
            analysis.clientScope = .sessions(sessions)
            analysis.sharedStateEffects = [.windowOption]

        case let .setPaneZoom(paneID, _):
            let pane = try requirePane(paneID, in: snapshot)
            let window = try requireWindow(pane.windowID, in: snapshot)
            let sessions = sessionIDs(linkedTo: window.id, snapshot: snapshot)
            analysis.target = paneTarget(pane, window: window)
            analysis.affectedSessionIDs = sessions
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = paneIDs(in: [window.id], snapshot: snapshot)
            analysis.clientScope = .sessions(sessions)
            analysis.sharedStateEffects = [.windowZoom]

        case let .resizePane(paneID, _, _), let .swapPane(paneID, _):
            let pane = try requirePane(paneID, in: snapshot)
            let window = try requireWindow(pane.windowID, in: snapshot)
            let sessions = sessionIDs(linkedTo: window.id, snapshot: snapshot)
            analysis.target = paneTarget(pane, window: window)
            analysis.affectedSessionIDs = sessions
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = paneIDs(in: [window.id], snapshot: snapshot)
            analysis.clientScope = .sessions(sessions)
            analysis.sharedStateEffects = [.windowPaneLayout]

        case let .chooseTree(paneID, _),
             let .enterCopyMode(paneID):
            let pane = try requirePane(paneID, in: snapshot)
            let window = try requireWindow(pane.windowID, in: snapshot)
            analysis.target = paneTarget(pane, window: window)
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = [pane.id]

        case let .killPane(paneID):
            let pane = try requirePane(paneID, in: snapshot)
            let window = try requireWindow(pane.windowID, in: snapshot)
            let sessions = sessionIDs(linkedTo: window.id, snapshot: snapshot)
            analysis.target = paneTarget(pane, window: window)
            analysis.affectedSessionIDs = sessions
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = [pane.id]
            analysis.destroyedPaneIDs = [pane.id]
            analysis.clientScope = .sessions(sessions)
            analysis.sharedStateEffects = [.windowPaneTopology]

            if snapshot.panes(in: window.id).count == 1 {
                let links = Set(snapshot.windowLinks.filter { $0.windowID == window.id })
                analysis.destroyedWindowIDs = [window.id]
                analysis.removedWindowLinks = links
                analysis.destroyedSessionIDs = sessions.filter { sessionID in
                    snapshot.windows(in: sessionID).allSatisfy { $0 == window.id }
                }
                analysis.sharedStateEffects.insert(.sessionWindowTopology)
                if !analysis.destroyedSessionIDs.isEmpty {
                    analysis.sharedStateEffects.formUnion([.clientAttachment, .sessionIdentity])
                }
            }

        case let .scrollPaneMode(paneID, _, _):
            let pane = try requirePane(paneID, in: snapshot)
            let window = try requireWindow(pane.windowID, in: snapshot)
            analysis.target = paneTarget(pane, window: window)
            analysis.affectedWindowIDs = [window.id]
            analysis.affectedPaneIDs = [pane.id]
        }

        let clientImpact = projectClientImpact(
            analysis.clientScope,
            snapshot: snapshot,
            context: context
        )
        return analysis.finish(
            otherAffectedClientIDs: clientImpact.affected,
            otherInteractiveClientIDs: clientImpact.interactive
        )
    }

    private func analyzeWindowDestruction(
        window: TmuxWindowSnapshot,
        snapshot: TmuxServerSnapshot,
        analysis: inout Analysis
    ) {
        let links = Set(snapshot.windowLinks.filter { $0.windowID == window.id })
        let sessions = Set(links.map(\.sessionID))
        let panes = paneIDs(in: [window.id], snapshot: snapshot)
        let destroyedSessions = Set(sessions.filter { sessionID in
            snapshot.windows(in: sessionID).allSatisfy { $0 == window.id }
        })

        analysis.target = .window(id: window.id, name: window.name)
        analysis.affectedSessionIDs = sessions
        analysis.affectedWindowIDs = [window.id]
        analysis.affectedPaneIDs = panes
        analysis.destroyedSessionIDs = destroyedSessions
        analysis.destroyedWindowIDs = [window.id]
        analysis.destroyedPaneIDs = panes
        analysis.removedWindowLinks = links
        analysis.clientScope = .sessions(sessions)
        analysis.sharedStateEffects = [.sessionWindowTopology, .windowPaneTopology]
        if !destroyedSessions.isEmpty {
            analysis.sharedStateEffects.formUnion([.clientAttachment, .sessionIdentity])
        }
    }

    private func requireSession(
        _ id: TmuxSessionID,
        in snapshot: TmuxServerSnapshot
    ) throws -> TmuxSessionSnapshot {
        guard let session = snapshot.sessions[id] else {
            throw TmuxOperationImpactError.missingSession(id)
        }
        return session
    }

    private func requireWindow(
        _ id: TmuxWindowID,
        in snapshot: TmuxServerSnapshot
    ) throws -> TmuxWindowSnapshot {
        guard let window = snapshot.windows[id] else {
            throw TmuxOperationImpactError.missingWindow(id)
        }
        return window
    }

    private func requirePane(
        _ id: TmuxPaneID,
        in snapshot: TmuxServerSnapshot
    ) throws -> TmuxPaneSnapshot {
        guard let pane = snapshot.panes[id] else {
            throw TmuxOperationImpactError.missingPane(id)
        }
        return pane
    }

    private func requireClient(
        _ target: TmuxClientTarget,
        in snapshot: TmuxServerSnapshot
    ) throws -> TmuxClientSnapshot {
        let matches = snapshot.clients.values.filter { $0.id.targetName == target.value }
        guard let client = matches.first else {
            throw TmuxOperationImpactError.missingClientTarget(target)
        }
        guard matches.count == 1 else {
            throw TmuxOperationImpactError.ambiguousClientTarget(target)
        }
        return client
    }

    private func requireOwnedInteractiveClient(
        _ target: TmuxClientTarget,
        in snapshot: TmuxServerSnapshot,
        context: TmuxOperationImpactContext
    ) throws -> TmuxClientSnapshot {
        let client = try requireClient(target, in: snapshot)
        guard case let .connInteractive(attachmentID) = client.role,
              client.kind == .interactiveTerminal
        else {
            throw TmuxOperationImpactError.clientTargetNotConnInteractive(client.id)
        }
        if let initiatingAttachmentID = context.initiatingAttachmentID,
           attachmentID != initiatingAttachmentID
        {
            throw TmuxOperationImpactError.clientTargetDoesNotMatchInitiatingAttachment(client.id)
        }
        return client
    }

    private func isLinked(
        windowID: TmuxWindowID,
        to sessionID: TmuxSessionID,
        in snapshot: TmuxServerSnapshot
    ) -> Bool {
        snapshot.windowLinks.contains {
            $0.windowID == windowID && $0.sessionID == sessionID
        }
    }

    private func sessionIDs(
        linkedTo windowID: TmuxWindowID,
        snapshot: TmuxServerSnapshot
    ) -> Set<TmuxSessionID> {
        Set(snapshot.windowLinks.lazy.filter { $0.windowID == windowID }.map(\.sessionID))
    }

    private func paneIDs(
        in windowIDs: Set<TmuxWindowID>,
        snapshot: TmuxServerSnapshot
    ) -> Set<TmuxPaneID> {
        Set(snapshot.panes.values.lazy.filter { windowIDs.contains($0.windowID) }.map(\.id))
    }

    private func paneTarget(
        _ pane: TmuxPaneSnapshot,
        window: TmuxWindowSnapshot
    ) -> TmuxOperationImpactTarget {
        .pane(
            id: pane.id,
            index: pane.index,
            windowID: window.id,
            windowName: window.name
        )
    }

    private func projectClientImpact(
        _ scope: ClientScope,
        snapshot: TmuxServerSnapshot,
        context: TmuxOperationImpactContext
    ) -> (affected: Set<TmuxClientID>, interactive: Set<TmuxClientID>) {
        let candidates: [TmuxClientSnapshot]
        switch scope {
        case .none:
            candidates = []
        case let .sessions(sessionIDs):
            candidates = snapshot.clients.values.filter { sessionIDs.contains($0.sessionID) }
        case let .clients(clientIDs):
            candidates = clientIDs.compactMap { snapshot.clients[$0] }
        }

        var affected: Set<TmuxClientID> = []
        var interactive: Set<TmuxClientID> = []
        for client in candidates {
            switch client.role {
            case .connControl:
                continue
            case let .connInteractive(attachmentID)
                where attachmentID == context.initiatingAttachmentID:
                continue
            case .connInteractive, .external:
                affected.insert(client.id)
                if client.kind == .interactiveTerminal || client.kind == .unknown {
                    interactive.insert(client.id)
                }
            }
        }
        return (affected, interactive)
    }
}

private enum ClientScope {
    case none
    case sessions(Set<TmuxSessionID>)
    case clients(Set<TmuxClientID>)
}

private struct Analysis {
    let semantics: TmuxOperationSemantics
    var target: TmuxOperationImpactTarget = .server
    var createdEntityKinds: Set<TmuxImpactEntityKind> = []
    var affectedSessionIDs: Set<TmuxSessionID> = []
    var affectedWindowIDs: Set<TmuxWindowID> = []
    var affectedPaneIDs: Set<TmuxPaneID> = []
    var destroyedSessionIDs: Set<TmuxSessionID> = []
    var destroyedWindowIDs: Set<TmuxWindowID> = []
    var destroyedPaneIDs: Set<TmuxPaneID> = []
    var removedWindowLinks: Set<TmuxWindowLink> = []
    var clientScope: ClientScope = .none
    var sharedStateEffects: Set<TmuxSharedStateEffect> = []

    func finish(
        otherAffectedClientIDs: Set<TmuxClientID>,
        otherInteractiveClientIDs: Set<TmuxClientID>
    ) -> TmuxOperationImpact {
        TmuxOperationImpact(
            semantics: semantics,
            target: target,
            createdEntityKinds: createdEntityKinds,
            affectedSessionIDs: affectedSessionIDs,
            affectedWindowIDs: affectedWindowIDs,
            affectedPaneIDs: affectedPaneIDs,
            destroyedSessionIDs: destroyedSessionIDs,
            destroyedWindowIDs: destroyedWindowIDs,
            destroyedPaneIDs: destroyedPaneIDs,
            removedWindowLinks: removedWindowLinks,
            otherAffectedClientIDs: otherAffectedClientIDs,
            otherInteractiveClientIDs: otherInteractiveClientIDs,
            sharedStateEffects: sharedStateEffects
        )
    }
}

private func tmuxSessionOrder(_ lhs: TmuxSessionID, _ rhs: TmuxSessionID) -> Bool {
    lhs.rawValue < rhs.rawValue
}

private func tmuxWindowOrder(_ lhs: TmuxWindowID, _ rhs: TmuxWindowID) -> Bool {
    lhs.rawValue < rhs.rawValue
}

private func tmuxPaneOrder(_ lhs: TmuxPaneID, _ rhs: TmuxPaneID) -> Bool {
    lhs.rawValue < rhs.rawValue
}

private func tmuxWindowLinkOrder(_ lhs: TmuxWindowLink, _ rhs: TmuxWindowLink) -> Bool {
    if lhs.sessionID != rhs.sessionID {
        return tmuxSessionOrder(lhs.sessionID, rhs.sessionID)
    }
    if lhs.index != rhs.index { return lhs.index < rhs.index }
    return tmuxWindowOrder(lhs.windowID, rhs.windowID)
}

private func tmuxClientOrder(_ lhs: TmuxClientID, _ rhs: TmuxClientID) -> Bool {
    if lhs.targetName != rhs.targetName { return lhs.targetName < rhs.targetName }
    if lhs.processID != rhs.processID { return (lhs.processID ?? .min) < (rhs.processID ?? .min) }
    return (lhs.createdAt ?? .min) < (rhs.createdAt ?? .min)
}
