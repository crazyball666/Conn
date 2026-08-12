import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux state reducer")
struct TmuxStateReducerTests {
    @Test("stale generations are discarded and a new server instance invalidates old IDs")
    func isolatesGenerationsAndServerInstances() throws {
        let fixture = try ReducerFixture()
        var reducer = TmuxStateReducer(snapshot: try fixture.snapshot, generation: 1)

        #expect(try reducer.apply(fixture.envelope(
            generation: 0,
            event: .sessionRenamed(fixture.session, name: "stale")
        )) == .discardedStaleGeneration)
        #expect(try reducer.reconcile(
            with: fixture.snapshot(observedAt: fixture.later),
            generation: 0
        ) == .discardedStaleGeneration)
        #expect(reducer.snapshot?.sessions[fixture.session]?.name == "one")

        let replacement = try fixture.snapshot(
            token: fixture.otherToken,
            sessions: [:],
            groups: [:],
            windows: [:],
            panes: [:],
            links: [],
            observedAt: fixture.later
        )
        #expect(try reducer.reconcile(with: replacement, generation: 2) == .applied)
        #expect(reducer.snapshot?.instance.token == fixture.otherToken)
        #expect(reducer.snapshot?.sessions[fixture.session] == nil)

        #expect(try reducer.apply(fixture.envelope(
            generation: 1,
            event: .sessionRenamed(fixture.session, name: "late old ID")
        )) == .discardedStaleGeneration)
    }

    @Test("same generation token mismatch clears all scoped IDs")
    func rejectsTokenMismatchWithinGeneration() throws {
        let fixture = try ReducerFixture()
        var reducer = TmuxStateReducer(snapshot: try fixture.snapshot, generation: 1)

        #expect(try reducer.apply(.init(
            generation: 1,
            serverToken: fixture.otherToken,
            observedAt: fixture.later,
            event: .sessionRenamed(fixture.session, name: "wrong server")
        )) == .serverInstanceChanged)
        #expect(reducer.snapshot == nil)
    }

    @Test("self-contained rename, selection and metadata events update normalized state")
    func appliesSelfContainedEvents() throws {
        let fixture = try ReducerFixture()
        var reducer = TmuxStateReducer(snapshot: try fixture.snapshot, generation: 1)

        #expect(try reducer.apply(fixture.envelope(
            event: .sessionRenamed(fixture.session, name: "renamed session")
        )) == .applied)
        #expect(try reducer.apply(fixture.envelope(
            event: .sessionCurrentWindowChanged(fixture.session, windowID: fixture.window2)
        )) == .applied)
        #expect(try reducer.apply(fixture.envelope(
            event: .windowRenamed(fixture.window1, name: "renamed window")
        )) == .applied)
        #expect(try reducer.apply(fixture.envelope(
            event: .windowActivePaneChanged(fixture.window1, paneID: fixture.pane2)
        )) == .applied)
        #expect(try reducer.apply(fixture.envelope(
            event: .windowZoomChanged(fixture.window1, isZoomed: true)
        )) == .applied)

        let title = TmuxObservedValue(
            value: "live title",
            freshness: .liveSubscription(observedAt: fixture.later)
        )
        let command = TmuxObservedValue(
            value: "nvim",
            freshness: .liveSubscription(observedAt: fixture.later)
        )
        let path = TmuxObservedValue(
            value: "/srv/app",
            freshness: .liveSubscription(observedAt: fixture.later)
        )
        #expect(try reducer.apply(fixture.envelope(
            event: .paneMetadataChanged(fixture.pane1, field: .title, value: title)
        )) == .applied)
        #expect(try reducer.apply(fixture.envelope(
            event: .paneMetadataChanged(fixture.pane1, field: .currentCommand, value: command)
        )) == .applied)
        #expect(try reducer.apply(fixture.envelope(
            event: .paneMetadataChanged(fixture.pane1, field: .currentPath, value: path)
        )) == .applied)

        let snapshot = try #require(reducer.snapshot)
        #expect(snapshot.sessions[fixture.session]?.name == "renamed session")
        #expect(snapshot.sessions[fixture.session]?.currentWindowID == fixture.window2)
        #expect(snapshot.windows[fixture.window1]?.name == "renamed window")
        #expect(snapshot.windows[fixture.window1]?.activePaneID == fixture.pane2)
        #expect(snapshot.windows[fixture.window1]?.isZoomed == true)
        #expect(snapshot.panes[fixture.pane1]?.title == title)
        #expect(snapshot.panes[fixture.pane1]?.currentCommand == command)
        #expect(snapshot.panes[fixture.pane1]?.currentPath == path)
    }

    @Test("revision changes for all state, impactRevision only for operational impact")
    func separatesDisplayAndImpactRevisions() throws {
        let fixture = try ReducerFixture()
        var reducer = TmuxStateReducer(snapshot: try fixture.snapshot, generation: 1)

        let metadata = TmuxObservedValue(
            value: "changed",
            freshness: .snapshot(observedAt: fixture.later)
        )
        _ = try reducer.apply(fixture.envelope(
            event: .paneMetadataChanged(fixture.pane1, field: .title, value: metadata)
        ))
        #expect(reducer.snapshot?.revision == 1)
        #expect(reducer.snapshot?.impactRevision == 0)

        _ = try reducer.apply(fixture.envelope(
            event: .sessionCurrentWindowChanged(fixture.session, windowID: fixture.window2)
        ))
        #expect(reducer.snapshot?.revision == 2)
        #expect(reducer.snapshot?.impactRevision == 0)

        _ = try reducer.apply(fixture.envelope(
            event: .windowRenamed(fixture.window1, name: "impact")
        ))
        #expect(reducer.snapshot?.revision == 3)
        #expect(reducer.snapshot?.impactRevision == 1)

        let changedTopology = try fixture.snapshot(
            groups: [:],
            clients: fixture.clients,
            observedAt: fixture.later
        )
        _ = try reducer.reconcile(with: changedTopology, generation: 1)
        #expect(reducer.snapshot?.revision == 4)
        #expect(reducer.snapshot?.impactRevision == 2)
    }

    @Test("full reconciliation detects group, link, Pane and client impact changes")
    func reconciliationTracksEveryImpactDimension() throws {
        let fixture = try ReducerFixture()
        var reducer = TmuxStateReducer(snapshot: try fixture.snapshot, generation: 1)

        let groupedSession = TmuxSessionSnapshot(
            id: fixture.session,
            name: "one",
            groupName: "team",
            currentWindowID: fixture.window1
        )
        let grouped = try fixture.snapshot(
            sessions: [fixture.session: groupedSession],
            groups: ["team": [fixture.session]],
            observedAt: fixture.later
        )
        _ = try reducer.reconcile(with: grouped, generation: 1)
        #expect(reducer.snapshot?.impactRevision == 1)

        var reorderedLinks = grouped.windowLinks
        reorderedLinks = reorderedLinks.map { link in
            TmuxWindowLink(
                sessionID: link.sessionID,
                windowID: link.windowID,
                index: link.index == 0 ? 1 : 0
            )
        }
        let reordered = try TmuxServerSnapshot(
            instance: grouped.instance,
            sessions: grouped.sessions,
            sessionGroups: grouped.sessionGroups,
            windows: grouped.windows,
            panes: grouped.panes,
            windowLinks: reorderedLinks,
            clients: grouped.clients,
            observedAt: fixture.later,
            revision: 0,
            impactRevision: 0
        )
        _ = try reducer.reconcile(with: reordered, generation: 1)
        #expect(reducer.snapshot?.impactRevision == 2)

        var resizedPanes = reordered.panes
        let pane = try #require(resizedPanes[fixture.pane1])
        resizedPanes[fixture.pane1] = TmuxPaneSnapshot(
            id: pane.id,
            windowID: pane.windowID,
            index: pane.index,
            title: pane.title,
            currentCommand: pane.currentCommand,
            currentPath: pane.currentPath,
            size: .init(cols: 100, rows: 30),
            isDead: pane.isDead
        )
        let resized = try TmuxServerSnapshot(
            instance: reordered.instance,
            sessions: reordered.sessions,
            sessionGroups: reordered.sessionGroups,
            windows: reordered.windows,
            panes: resizedPanes,
            windowLinks: reordered.windowLinks,
            clients: reordered.clients,
            observedAt: fixture.later,
            revision: 0,
            impactRevision: 0
        )
        _ = try reducer.reconcile(with: resized, generation: 1)
        #expect(reducer.snapshot?.impactRevision == 3)

        let withClients = try TmuxServerSnapshot(
            instance: resized.instance,
            sessions: resized.sessions,
            sessionGroups: resized.sessionGroups,
            windows: resized.windows,
            panes: resized.panes,
            windowLinks: resized.windowLinks,
            clients: fixture.clients,
            observedAt: fixture.later,
            revision: 0,
            impactRevision: 0
        )
        _ = try reducer.reconcile(with: withClients, generation: 1)
        #expect(reducer.snapshot?.impactRevision == 4)
    }

    @Test("incomplete topology signals reconcile without partial mutation")
    func requestsScopedReconciliation() throws {
        let fixture = try ReducerFixture()
        let cases: [(TmuxStateEvent, TmuxStateReduction)] = [
            (.windowLayoutChanged(fixture.window1), .reconcile(.window(fixture.window1))),
            (.windowAdded(sessionID: fixture.session), .reconcile(.session(fixture.session))),
            (.windowClosed(fixture.window1), .reconcile(.server)),
            (.sessionsChanged, .reconcile(.server)),
            (.clientsChanged(sessionID: fixture.session), .reconcile(.clients(fixture.session))),
            (.unknownNotification(name: "future-event"), .reconcile(.server)),
            (.protocolViolation, .reconcile(.server)),
        ]

        for (event, expected) in cases {
            var reducer = TmuxStateReducer(snapshot: try fixture.snapshot, generation: 1)
            let before = reducer.snapshot
            #expect(try reducer.apply(fixture.envelope(event: event)) == expected)
            #expect(reducer.snapshot == before)
        }
    }

    @Test("missing targets reconcile and pane output never enters snapshot state")
    func handlesMissingTargetsAndPaneOutput() throws {
        let fixture = try ReducerFixture()
        let missingPane = try #require(TmuxPaneID(rawValue: "%99"))
        var reducer = TmuxStateReducer(snapshot: try fixture.snapshot, generation: 1)

        #expect(try reducer.apply(fixture.envelope(
            event: .paneMetadataChanged(
                missingPane,
                field: .title,
                value: .unavailable
            )
        )) == .reconcile(.pane(missingPane)))

        let before = reducer.snapshot
        #expect(try reducer.apply(fixture.envelope(
            event: .paneOutput(fixture.pane1, Data([0xFF]))
        )) == .unchanged)
        #expect(reducer.snapshot == before)
    }
}

private struct ReducerFixture {
    let session: TmuxSessionID
    let window1: TmuxWindowID
    let window2: TmuxWindowID
    let pane1: TmuxPaneID
    let pane2: TmuxPaneID
    let token: TmuxServerInstanceToken
    let otherToken: TmuxServerInstanceToken
    let observedAt = Date(timeIntervalSince1970: 100)
    let later = Date(timeIntervalSince1970: 200)

    var snapshot: TmuxServerSnapshot {
        get throws { try makeSnapshot() }
    }

    var clients: [TmuxClientID: TmuxClientSnapshot] {
        let id = TmuxClientID(targetName: "/dev/pts/9", processID: 9, createdAt: 9)
        return [id: .init(
            id: id,
            sessionID: session,
            currentWindowID: window1,
            activePaneID: pane1,
            flags: nil,
            role: .external,
            kind: .unknown,
            sizeParticipation: .unknown,
            observedAt: later
        )]
    }

    init() throws {
        session = try #require(TmuxSessionID(rawValue: "$1"))
        window1 = try #require(TmuxWindowID(rawValue: "@1"))
        window2 = try #require(TmuxWindowID(rawValue: "@2"))
        pane1 = try #require(TmuxPaneID(rawValue: "%1"))
        pane2 = try #require(TmuxPaneID(rawValue: "%2"))
        token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
        otherToken = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 101,
            serverStartTime: 300
        )
    }

    func envelope(
        generation: UInt64 = 1,
        event: TmuxStateEvent
    ) -> TmuxStateEventEnvelope {
        .init(
            generation: generation,
            serverToken: token,
            observedAt: later,
            event: event
        )
    }

    func snapshot(
        token: TmuxServerInstanceToken? = nil,
        sessions: [TmuxSessionID: TmuxSessionSnapshot]? = nil,
        groups: [String: Set<TmuxSessionID>]? = nil,
        windows: [TmuxWindowID: TmuxWindowSnapshot]? = nil,
        panes: [TmuxPaneID: TmuxPaneSnapshot]? = nil,
        links: [TmuxWindowLink]? = nil,
        clients: [TmuxClientID: TmuxClientSnapshot] = [:],
        observedAt: Date? = nil
    ) throws -> TmuxServerSnapshot {
        try makeSnapshot(
            token: token,
            sessions: sessions,
            groups: groups,
            windows: windows,
            panes: panes,
            links: links,
            clients: clients,
            observedAt: observedAt
        )
    }

    private func makeSnapshot(
        token: TmuxServerInstanceToken? = nil,
        sessions: [TmuxSessionID: TmuxSessionSnapshot]? = nil,
        groups: [String: Set<TmuxSessionID>]? = nil,
        windows: [TmuxWindowID: TmuxWindowSnapshot]? = nil,
        panes: [TmuxPaneID: TmuxPaneSnapshot]? = nil,
        links: [TmuxWindowLink]? = nil,
        clients: [TmuxClientID: TmuxClientSnapshot] = [:],
        observedAt: Date? = nil
    ) throws -> TmuxServerSnapshot {
        try TmuxServerSnapshot(
            instance: .init(token: token ?? self.token, version: "tmux 3.5a"),
            sessions: sessions ?? [session: .init(
                id: session,
                name: "one",
                groupName: nil,
                currentWindowID: window1
            )],
            sessionGroups: groups ?? [:],
            windows: windows ?? [
                window1: .init(
                    id: window1,
                    name: "first",
                    layout: nil,
                    isZoomed: false,
                    activePaneID: pane1
                ),
                window2: .init(
                    id: window2,
                    name: "second",
                    layout: nil,
                    isZoomed: false,
                    activePaneID: nil
                ),
            ],
            panes: panes ?? [
                pane1: .init(
                    id: pane1,
                    windowID: window1,
                    index: 0,
                    title: .unavailable,
                    currentCommand: .unavailable,
                    currentPath: .unavailable,
                    size: .init(cols: 80, rows: 24),
                    isDead: false
                ),
                pane2: .init(
                    id: pane2,
                    windowID: window1,
                    index: 1,
                    title: .unavailable,
                    currentCommand: .unavailable,
                    currentPath: .unavailable,
                    size: .init(cols: 40, rows: 24),
                    isDead: false
                ),
            ],
            windowLinks: links ?? [
                .init(sessionID: session, windowID: window1, index: 0),
                .init(sessionID: session, windowID: window2, index: 1),
            ],
            clients: clients,
            observedAt: observedAt ?? self.observedAt,
            revision: 0,
            impactRevision: 0
        )
    }
}
