import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("normalized tmux snapshots")
struct TmuxSnapshotTests {
    @Test("one Window entity may be linked into multiple grouped Sessions")
    func modelsSharedWindowGraph() throws {
        let fixture = try SnapshotFixture()
        let snapshot = try fixture.makeSnapshot()

        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windowLinks.count == 2)
        #expect(snapshot.windows(in: fixture.session1) == [fixture.window])
        #expect(snapshot.windows(in: fixture.session2) == [fixture.window])
        #expect(snapshot.panes(in: fixture.window) == [fixture.pane])
        #expect(snapshot.sessionGroups["team"] == [fixture.session1, fixture.session2])
    }

    @Test("client projections keep ownership, kind and size participation orthogonal")
    func projectsConservativeClientRisk() throws {
        let fixture = try SnapshotFixture()
        let snapshot = try fixture.makeSnapshot(clients: fixture.clients)

        #expect(snapshot.externalAttachedClientCount(in: fixture.session1) == 2)
        #expect(snapshot.affectedAttachedClientCount(in: fixture.session1) == 3)
        #expect(snapshot.interactiveClientCount(in: fixture.session1) == 2)
        #expect(snapshot.sizeParticipatingClientCount(in: fixture.session1) == 2)
        #expect(snapshot.otherAffectedClientCount(
            in: fixture.session1,
            relativeToAttachmentID: "attachment-1"
        ) == 2)
        #expect(snapshot.otherInteractiveClientCount(
            in: fixture.session1,
            relativeToAttachmentID: "attachment-1"
        ) == 1)
    }

    @Test("dictionary keys and all graph references are validated")
    func validatesGraphReferences() throws {
        let fixture = try SnapshotFixture()
        let otherSession = try #require(TmuxSessionID(rawValue: "$9"))
        let otherWindow = try #require(TmuxWindowID(rawValue: "@9"))
        let otherPane = try #require(TmuxPaneID(rawValue: "%9"))

        #expect(throws: TmuxSnapshotValidationError.sessionKeyMismatch(
            key: otherSession,
            value: fixture.session1
        )) {
            try fixture.makeSnapshot(sessions: [
                otherSession: fixture.sessionSnapshot1,
                fixture.session2: fixture.sessionSnapshot2,
            ])
        }
        #expect(throws: TmuxSnapshotValidationError.missingLinkedWindow(otherWindow)) {
            try fixture.makeSnapshot(windowLinks: [
                .init(sessionID: fixture.session1, windowID: otherWindow, index: 0),
            ])
        }
        #expect(throws: TmuxSnapshotValidationError.missingPaneWindow(
            paneID: otherPane,
            windowID: otherWindow
        )) {
            let pane = TmuxPaneSnapshot(
                id: otherPane,
                windowID: otherWindow,
                index: 0,
                title: .unavailable,
                currentCommand: .unavailable,
                currentPath: .unavailable,
                size: .init(cols: 80, rows: 24),
                isDead: false
            )
            _ = try fixture.makeSnapshot(panes: [otherPane: pane])
        }
    }

    @Test("current Window, active Pane, groups and duplicate links preserve invariants")
    func rejectsInvalidTopology() throws {
        let fixture = try SnapshotFixture()
        let otherWindow = try #require(TmuxWindowID(rawValue: "@9"))
        let otherPane = try #require(TmuxPaneID(rawValue: "%9"))

        let invalidSession = TmuxSessionSnapshot(
            id: fixture.session1,
            name: "one",
            groupName: "team",
            currentWindowID: otherWindow
        )
        #expect(throws: TmuxSnapshotValidationError.missingCurrentWindow(
            sessionID: fixture.session1,
            windowID: otherWindow
        )) {
            try fixture.makeSnapshot(sessions: [
                fixture.session1: invalidSession,
                fixture.session2: fixture.sessionSnapshot2,
            ])
        }

        let invalidWindow = TmuxWindowSnapshot(
            id: fixture.window,
            name: "shared",
            layout: nil,
            isZoomed: false,
            activePaneID: otherPane
        )
        #expect(throws: TmuxSnapshotValidationError.missingActivePane(
            windowID: fixture.window,
            paneID: otherPane
        )) {
            try fixture.makeSnapshot(windows: [fixture.window: invalidWindow])
        }

        #expect(throws: TmuxSnapshotValidationError.duplicateWindowLink(
            sessionID: fixture.session1,
            windowID: fixture.window,
            index: 0
        )) {
            try fixture.makeSnapshot(windowLinks: fixture.links + [fixture.links[0]])
        }

        #expect(throws: TmuxSnapshotValidationError.groupMembershipMismatch(
            groupName: "team",
            sessionID: fixture.session2
        )) {
            try fixture.makeSnapshot(sessionGroups: ["team": [fixture.session1]])
        }

        #expect(throws: TmuxSnapshotValidationError.invalidWindowLinkIndex(
            sessionID: fixture.session1,
            index: -1
        )) {
            try fixture.makeSnapshot(windowLinks: [
                .init(sessionID: fixture.session1, windowID: fixture.window, index: -1),
                fixture.links[1],
            ])
        }

        let secondPaneID = try #require(TmuxPaneID(rawValue: "%2"))
        let secondPane = TmuxPaneSnapshot(
            id: secondPaneID,
            windowID: fixture.window,
            index: 0,
            title: .unavailable,
            currentCommand: .unavailable,
            currentPath: .unavailable,
            size: .init(cols: 80, rows: 24),
            isDead: false
        )
        #expect(throws: TmuxSnapshotValidationError.duplicatePaneIndex(
            windowID: fixture.window,
            index: 0
        )) {
            try fixture.makeSnapshot(panes: [
                fixture.pane: fixture.paneSnapshot,
                secondPaneID: secondPane,
            ])
        }
    }

    @Test("Conn Control Client can never be represented as a size participant")
    func rejectsSizeParticipatingControlClient() throws {
        let fixture = try SnapshotFixture()
        let clientID = TmuxClientID(targetName: "/dev/pts/control", processID: 10, createdAt: 20)
        let client = TmuxClientSnapshot(
            id: clientID,
            sessionID: fixture.session1,
            currentWindowID: fixture.window,
            activePaneID: fixture.pane,
            flags: nil,
            role: .connControl(sessionID: fixture.session1),
            kind: .controlMode,
            sizeParticipation: .unknown,
            observedAt: fixture.observedAt
        )

        #expect(throws: TmuxSnapshotValidationError.controlClientMayParticipateInSize(clientID)) {
            _ = try fixture.makeSnapshot(clients: [clientID: client])
        }

        let wrongKind = TmuxClientSnapshot(
            id: clientID,
            sessionID: fixture.session1,
            currentWindowID: fixture.window,
            activePaneID: fixture.pane,
            flags: nil,
            role: .connControl(sessionID: fixture.session1),
            kind: .interactiveTerminal,
            sizeParticipation: .notParticipating,
            observedAt: fixture.observedAt
        )
        #expect(throws: TmuxSnapshotValidationError.controlClientKindMismatch(clientID)) {
            try fixture.makeSnapshot(clients: [clientID: wrongKind])
        }
    }
}

private struct SnapshotFixture {
    let session1: TmuxSessionID
    let session2: TmuxSessionID
    let window: TmuxWindowID
    let pane: TmuxPaneID
    let instance: TmuxServerInstance
    let observedAt = Date(timeIntervalSince1970: 100)

    var sessionSnapshot1: TmuxSessionSnapshot {
        .init(id: session1, name: "one", groupName: "team", currentWindowID: window)
    }

    var sessionSnapshot2: TmuxSessionSnapshot {
        .init(id: session2, name: "two", groupName: "team", currentWindowID: window)
    }

    var windowSnapshot: TmuxWindowSnapshot {
        .init(id: window, name: "shared", layout: nil, isZoomed: false, activePaneID: pane)
    }

    var paneSnapshot: TmuxPaneSnapshot {
        .init(
            id: pane,
            windowID: window,
            index: 0,
            title: .init(value: "title", freshness: .snapshot(observedAt: observedAt)),
            currentCommand: .unavailable,
            currentPath: .unavailable,
            size: .init(cols: 80, rows: 24),
            isDead: false
        )
    }

    var links: [TmuxWindowLink] {
        [
            .init(sessionID: session1, windowID: window, index: 0),
            .init(sessionID: session2, windowID: window, index: 0),
        ]
    }

    var clients: [TmuxClientID: TmuxClientSnapshot] {
        let interactiveID = TmuxClientID(
            targetName: "/dev/pts/1",
            processID: 1,
            createdAt: 10
        )
        let controlID = TmuxClientID(
            targetName: "/dev/pts/2",
            processID: 2,
            createdAt: 20
        )
        let externalControlID = TmuxClientID(
            targetName: "/dev/pts/3",
            processID: 3,
            createdAt: 30
        )
        let externalInteractiveID = TmuxClientID(
            targetName: "/dev/pts/4",
            processID: 4,
            createdAt: 40
        )
        return [
            interactiveID: .init(
                id: interactiveID,
                sessionID: session1,
                currentWindowID: window,
                activePaneID: pane,
                flags: [],
                role: .connInteractive(attachmentID: "attachment-1"),
                kind: .interactiveTerminal,
                sizeParticipation: .participating,
                observedAt: observedAt
            ),
            controlID: .init(
                id: controlID,
                sessionID: session1,
                currentWindowID: window,
                activePaneID: pane,
                flags: [.noOutput, .ignoreSize],
                role: .connControl(sessionID: session1),
                kind: .controlMode,
                sizeParticipation: .notParticipating,
                observedAt: observedAt
            ),
            externalControlID: .init(
                id: externalControlID,
                sessionID: session1,
                currentWindowID: window,
                activePaneID: pane,
                flags: nil,
                role: .external,
                kind: .controlMode,
                sizeParticipation: .unknown,
                observedAt: observedAt
            ),
            externalInteractiveID: .init(
                id: externalInteractiveID,
                sessionID: session1,
                currentWindowID: window,
                activePaneID: pane,
                flags: [.ignoreSize],
                role: .external,
                kind: .interactiveTerminal,
                sizeParticipation: .ignored,
                observedAt: observedAt
            ),
        ]
    }

    init() throws {
        session1 = try #require(TmuxSessionID(rawValue: "$1"))
        session2 = try #require(TmuxSessionID(rawValue: "$2"))
        window = try #require(TmuxWindowID(rawValue: "@1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        instance = TmuxServerInstance(
            token: try TmuxServerInstanceToken(
                resolvedSocketPath: "/tmp/tmux/default",
                serverPID: 100,
                serverStartTime: 200
            ),
            version: "tmux 3.5a"
        )
    }

    func makeSnapshot(
        sessions: [TmuxSessionID: TmuxSessionSnapshot]? = nil,
        sessionGroups: [String: Set<TmuxSessionID>]? = nil,
        windows: [TmuxWindowID: TmuxWindowSnapshot]? = nil,
        panes: [TmuxPaneID: TmuxPaneSnapshot]? = nil,
        windowLinks: [TmuxWindowLink]? = nil,
        clients: [TmuxClientID: TmuxClientSnapshot] = [:]
    ) throws -> TmuxServerSnapshot {
        try TmuxServerSnapshot(
            instance: instance,
            sessions: sessions ?? [
                session1: sessionSnapshot1,
                session2: sessionSnapshot2,
            ],
            sessionGroups: sessionGroups ?? ["team": [session1, session2]],
            windows: windows ?? [window: windowSnapshot],
            panes: panes ?? [pane: paneSnapshot],
            windowLinks: windowLinks ?? links,
            clients: clients,
            observedAt: observedAt,
            revision: 1,
            impactRevision: 1
        )
    }
}
