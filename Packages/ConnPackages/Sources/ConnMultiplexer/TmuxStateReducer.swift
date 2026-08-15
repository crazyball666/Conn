import Foundation

package enum TmuxPaneMetadataField: Sendable, Equatable {
    case title
    case currentCommand
    case currentPath
}

package enum TmuxReconciliationScope: Sendable, Equatable {
    case server
    case session(TmuxSessionID)
    case window(TmuxWindowID)
    case pane(TmuxPaneID)
    case clients(TmuxSessionID)
}

/// Typed state input produced after protocol notifications or subscriptions have been
/// decoded. Events that do not carry enough data to preserve graph invariants are explicit
/// invalidation signals, not speculative partial mutations.
package enum TmuxStateEvent: Sendable, Equatable {
    case sessionRenamed(TmuxSessionID, name: String)
    case sessionCurrentWindowChanged(TmuxSessionID, windowID: TmuxWindowID)
    case windowRenamed(TmuxWindowID, name: String)
    case windowActivePaneChanged(TmuxWindowID, paneID: TmuxPaneID)
    case windowZoomChanged(TmuxWindowID, isZoomed: Bool)
    case paneMetadataChanged(
        TmuxPaneID,
        field: TmuxPaneMetadataField,
        value: TmuxObservedValue<String>
    )

    case windowLayoutChanged(TmuxWindowID)
    case windowAdded(sessionID: TmuxSessionID)
    case windowClosed(TmuxWindowID)
    case sessionsChanged
    case clientsChanged(sessionID: TmuxSessionID)
    case unknownNotification(name: String)
    case protocolViolation

    /// Pane bytes belong to the current/future renderer, never to the topology snapshot.
    case paneOutput(TmuxPaneID, Data)
}

package struct TmuxStateEventEnvelope: Sendable, Equatable {
    package let generation: UInt64
    package let serverToken: TmuxServerInstanceToken
    package let observedAt: Date
    package let event: TmuxStateEvent

    package init(
        generation: UInt64,
        serverToken: TmuxServerInstanceToken,
        observedAt: Date,
        event: TmuxStateEvent
    ) {
        self.generation = generation
        self.serverToken = serverToken
        self.observedAt = observedAt
        self.event = event
    }
}

package enum TmuxStateReduction: Sendable, Equatable {
    case applied
    case unchanged
    case discardedStaleGeneration
    case reconcile(TmuxReconciliationScope)
    case serverInstanceChanged
}

/// Pure, generation-aware owner of one normalized server snapshot. The future Hub actor
/// serializes calls to this value; transport, command deadlines, and retry policy stay out.
package struct TmuxStateReducer: Sendable {
    package private(set) var snapshot: TmuxServerSnapshot?
    package private(set) var generation: UInt64

    private var expectedServerToken: TmuxServerInstanceToken

    package init(snapshot: TmuxServerSnapshot, generation: UInt64) {
        self.snapshot = snapshot
        self.generation = generation
        expectedServerToken = snapshot.instance.token
    }

    package mutating func apply(
        _ envelope: TmuxStateEventEnvelope
    ) throws -> TmuxStateReduction {
        if envelope.generation < generation {
            return .discardedStaleGeneration
        }
        guard envelope.generation == generation else {
            return .reconcile(.server)
        }
        guard envelope.serverToken == expectedServerToken else {
            snapshot = nil
            return .serverInstanceChanged
        }
        guard let current = snapshot else {
            return .reconcile(.server)
        }

        switch envelope.event {
        case let .sessionRenamed(sessionID, name):
            guard let session = current.sessions[sessionID] else {
                return .reconcile(.session(sessionID))
            }
            guard session.name != name else { return .unchanged }
            var sessions = current.sessions
            sessions[sessionID] = TmuxSessionSnapshot(
                id: session.id,
                name: name,
                groupName: session.groupName,
                currentWindowID: session.currentWindowID
            )
            return try commit(
                current,
                sessions: sessions,
                observedAt: envelope.observedAt,
                impactsOperations: true
            )

        case let .sessionCurrentWindowChanged(sessionID, windowID):
            guard let session = current.sessions[sessionID] else {
                return .reconcile(.session(sessionID))
            }
            guard current.windows[windowID] != nil,
                  current.windowLinks.contains(where: {
                      $0.sessionID == sessionID && $0.windowID == windowID
                  })
            else {
                return .reconcile(.session(sessionID))
            }
            guard session.currentWindowID != windowID else { return .unchanged }
            var sessions = current.sessions
            sessions[sessionID] = TmuxSessionSnapshot(
                id: session.id,
                name: session.name,
                groupName: session.groupName,
                currentWindowID: windowID
            )
            return try commit(
                current,
                sessions: sessions,
                observedAt: envelope.observedAt,
                impactsOperations: false
            )

        case let .windowRenamed(windowID, name):
            guard let window = current.windows[windowID] else {
                return .reconcile(.window(windowID))
            }
            guard window.name != name else { return .unchanged }
            var windows = current.windows
            windows[windowID] = TmuxWindowSnapshot(
                id: window.id,
                name: name,
                layout: window.layout,
                isZoomed: window.isZoomed,
                activePaneID: window.activePaneID
            )
            return try commit(
                current,
                windows: windows,
                observedAt: envelope.observedAt,
                impactsOperations: true
            )

        case let .windowActivePaneChanged(windowID, paneID):
            guard let window = current.windows[windowID] else {
                return .reconcile(.window(windowID))
            }
            guard current.panes[paneID]?.windowID == windowID else {
                return .reconcile(.window(windowID))
            }
            guard window.activePaneID != paneID else { return .unchanged }
            var windows = current.windows
            windows[windowID] = TmuxWindowSnapshot(
                id: window.id,
                name: window.name,
                layout: window.layout,
                isZoomed: window.isZoomed,
                activePaneID: paneID
            )
            return try commit(
                current,
                windows: windows,
                observedAt: envelope.observedAt,
                impactsOperations: false
            )

        case let .windowZoomChanged(windowID, isZoomed):
            guard let window = current.windows[windowID] else {
                return .reconcile(.window(windowID))
            }
            guard window.isZoomed != isZoomed else { return .unchanged }
            var windows = current.windows
            windows[windowID] = TmuxWindowSnapshot(
                id: window.id,
                name: window.name,
                layout: window.layout,
                isZoomed: isZoomed,
                activePaneID: window.activePaneID
            )
            return try commit(
                current,
                windows: windows,
                observedAt: envelope.observedAt,
                impactsOperations: true
            )

        case let .paneMetadataChanged(paneID, field, value):
            guard let pane = current.panes[paneID] else {
                return .reconcile(.pane(paneID))
            }
            let changed: Bool
            switch field {
            case .title:
                changed = pane.title != value
            case .currentCommand:
                changed = pane.currentCommand != value
            case .currentPath:
                changed = pane.currentPath != value
            }
            guard changed else { return .unchanged }

            var panes = current.panes
            panes[paneID] = TmuxPaneSnapshot(
                id: pane.id,
                windowID: pane.windowID,
                index: pane.index,
                title: field == .title ? value : pane.title,
                currentCommand: field == .currentCommand ? value : pane.currentCommand,
                currentPath: field == .currentPath ? value : pane.currentPath,
                interaction: pane.interaction,
                size: pane.size,
                isDead: pane.isDead
            )
            return try commit(
                current,
                panes: panes,
                observedAt: envelope.observedAt,
                impactsOperations: false
            )

        case let .windowLayoutChanged(windowID):
            return .reconcile(.window(windowID))
        case let .windowAdded(sessionID):
            return .reconcile(.session(sessionID))
        case .windowClosed, .sessionsChanged, .unknownNotification, .protocolViolation:
            return .reconcile(.server)
        case let .clientsChanged(sessionID):
            return .reconcile(.clients(sessionID))
        case .paneOutput:
            return .unchanged
        }
    }

    /// Atomically installs a validated reconciliation snapshot. Revision numbers are owned
    /// here rather than trusted from the snapshot producer, so all consumers observe one
    /// monotonic state sequence across incremental and full updates.
    package mutating func reconcile(
        with incoming: TmuxServerSnapshot,
        generation incomingGeneration: UInt64
    ) throws -> TmuxStateReduction {
        if incomingGeneration < generation {
            return .discardedStaleGeneration
        }
        if incomingGeneration == generation,
           incoming.instance.token != expectedServerToken
        {
            snapshot = nil
            return .serverInstanceChanged
        }

        guard let current = snapshot else {
            guard incomingGeneration > generation else {
                return .reconcile(.server)
            }
            snapshot = incoming
            generation = incomingGeneration
            expectedServerToken = incoming.instance.token
            return .applied
        }

        if incomingGeneration == generation,
           sameState(current, incoming),
           current.observedAt == incoming.observedAt
        {
            return .unchanged
        }

        guard let nextRevision = increment(current.revision),
              let nextImpactRevision = sameOperationalImpact(current, incoming)
                ? current.impactRevision
                : increment(current.impactRevision)
        else {
            return .reconcile(.server)
        }

        let adjusted = try TmuxServerSnapshot(
            instance: incoming.instance,
            sessions: incoming.sessions,
            sessionGroups: incoming.sessionGroups,
            windows: incoming.windows,
            panes: incoming.panes,
            windowLinks: incoming.windowLinks,
            clients: incoming.clients,
            observedAt: incoming.observedAt,
            revision: nextRevision,
            impactRevision: nextImpactRevision
        )
        snapshot = adjusted
        generation = incomingGeneration
        expectedServerToken = incoming.instance.token
        return .applied
    }

    private mutating func commit(
        _ current: TmuxServerSnapshot,
        sessions: [TmuxSessionID: TmuxSessionSnapshot]? = nil,
        windows: [TmuxWindowID: TmuxWindowSnapshot]? = nil,
        panes: [TmuxPaneID: TmuxPaneSnapshot]? = nil,
        observedAt: Date,
        impactsOperations: Bool
    ) throws -> TmuxStateReduction {
        guard let nextRevision = increment(current.revision),
              let nextImpactRevision = impactsOperations
                ? increment(current.impactRevision)
                : current.impactRevision
        else {
            return .reconcile(.server)
        }

        let updated = try TmuxServerSnapshot(
            instance: current.instance,
            sessions: sessions ?? current.sessions,
            sessionGroups: current.sessionGroups,
            windows: windows ?? current.windows,
            panes: panes ?? current.panes,
            windowLinks: current.windowLinks,
            clients: current.clients,
            observedAt: observedAt,
            revision: nextRevision,
            impactRevision: nextImpactRevision
        )
        snapshot = updated
        return .applied
    }

    private func increment(_ value: UInt64) -> UInt64? {
        let (next, overflow) = value.addingReportingOverflow(1)
        return overflow ? nil : next
    }

    private func sameState(
        _ lhs: TmuxServerSnapshot,
        _ rhs: TmuxServerSnapshot
    ) -> Bool {
        lhs.instance == rhs.instance
            && lhs.sessions == rhs.sessions
            && lhs.sessionGroups == rhs.sessionGroups
            && lhs.windows == rhs.windows
            && lhs.panes == rhs.panes
            && Set(lhs.windowLinks) == Set(rhs.windowLinks)
            && lhs.clients == rhs.clients
    }

    private func sameOperationalImpact(
        _ lhs: TmuxServerSnapshot,
        _ rhs: TmuxServerSnapshot
    ) -> Bool {
        guard lhs.instance.token == rhs.instance.token,
              lhs.sessionGroups == rhs.sessionGroups,
              Set(lhs.windowLinks) == Set(rhs.windowLinks),
              lhs.sessions.keys == rhs.sessions.keys,
              lhs.windows.keys == rhs.windows.keys,
              lhs.panes.keys == rhs.panes.keys,
              lhs.clients.keys == rhs.clients.keys
        else {
            return false
        }

        for id in lhs.sessions.keys {
            guard let left = lhs.sessions[id], let right = rhs.sessions[id],
                  left.name == right.name,
                  left.groupName == right.groupName
            else { return false }
        }
        for id in lhs.windows.keys {
            guard let left = lhs.windows[id], let right = rhs.windows[id],
                  left.name == right.name,
                  left.layout == right.layout,
                  left.isZoomed == right.isZoomed
            else { return false }
        }
        for id in lhs.panes.keys {
            guard let left = lhs.panes[id], let right = rhs.panes[id],
                  left.windowID == right.windowID,
                  left.index == right.index,
                  left.size == right.size,
                  left.isDead == right.isDead
            else { return false }
        }
        for id in lhs.clients.keys {
            guard let left = lhs.clients[id], let right = rhs.clients[id],
                  left.sessionID == right.sessionID,
                  left.currentWindowID == right.currentWindowID,
                  left.activePaneID == right.activePaneID,
                  left.flags == right.flags,
                  left.role == right.role,
                  left.kind == right.kind,
                  left.sizeParticipation == right.sizeParticipation
            else { return false }
        }
        return true
    }
}
