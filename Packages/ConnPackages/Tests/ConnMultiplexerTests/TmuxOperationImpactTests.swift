import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux operation impact analysis")
struct TmuxOperationImpactTests {
    @Test("typed targets must exist and client-scoped targets must be reachable")
    func validatesTargetsAndClientReachability() throws {
        let fixture = try ImpactFixture()
        let snapshot = try fixture.snapshot()
        let missingSession = try #require(TmuxSessionID(rawValue: "$99"))
        let missingWindow = try #require(TmuxWindowID(rawValue: "@99"))
        let missingPane = try #require(TmuxPaneID(rawValue: "%99"))
        let missingClient = try TmuxClientTarget("/dev/pts/missing")
        let session3Client = try TmuxClientTarget(fixture.session3Client.targetName)
        let analyzer = TmuxOperationImpactAnalyzer()

        #expect(throws: TmuxOperationImpactError.missingSession(missingSession)) {
            try analyzer.analyze(.killSession(missingSession), in: snapshot)
        }
        #expect(throws: TmuxOperationImpactError.missingWindow(missingWindow)) {
            try analyzer.analyze(.killWindow(missingWindow), in: snapshot)
        }
        #expect(throws: TmuxOperationImpactError.missingPane(missingPane)) {
            try analyzer.analyze(.killPane(missingPane), in: snapshot)
        }
        #expect(throws: TmuxOperationImpactError.missingClientTarget(missingClient)) {
            try analyzer.analyze(.detachClient(missingClient), in: snapshot)
        }
        #expect(throws: TmuxOperationImpactError.windowNotLinkedToClientSession(
            windowID: fixture.sharedWindow,
            clientID: fixture.session3Client
        )) {
            try analyzer.analyze(
                .selectWindow(fixture.sharedWindow, for: session3Client),
                in: snapshot
            )
        }
        #expect(throws: TmuxOperationImpactError.paneNotLinkedToClientSession(
            paneID: fixture.sharedPane1,
            clientID: fixture.session3Client
        )) {
            try analyzer.analyze(
                .selectPane(fixture.sharedPane1, for: session3Client),
                in: snapshot
            )
        }

        let duplicateID = TmuxClientID(
            targetName: fixture.currentClient.targetName,
            processID: 999,
            createdAt: 999
        )
        let duplicate = fixture.client(
            id: duplicateID,
            sessionID: fixture.session1,
            role: .external,
            kind: .unknown,
            sizeParticipation: .unknown
        )
        var ambiguousClients = fixture.clients
        ambiguousClients[duplicateID] = duplicate
        let ambiguousSnapshot = try fixture.snapshot(clients: ambiguousClients)
        let currentTarget = try TmuxClientTarget(fixture.currentClient.targetName)
        #expect(throws: TmuxOperationImpactError.ambiguousClientTarget(currentTarget)) {
            try analyzer.analyze(.detachClient(currentTarget), in: ambiguousSnapshot)
        }
    }

    @Test("client mutations are restricted to the initiating Conn interactive attachment")
    func restrictsClientMutationsToOwnedInteractiveAttachment() throws {
        let fixture = try ImpactFixture()
        let snapshot = try fixture.snapshot()
        let controlTarget = try TmuxClientTarget(fixture.hubControlClient.targetName)
        let externalTarget = try TmuxClientTarget(fixture.externalInteractiveClient.targetName)
        let currentTarget = try TmuxClientTarget(fixture.currentClient.targetName)
        let analyzer = TmuxOperationImpactAnalyzer()

        #expect(throws: TmuxOperationImpactError.clientTargetNotConnInteractive(
            fixture.hubControlClient
        )) {
            try analyzer.analyze(
                .selectWindow(fixture.sharedWindow, for: controlTarget),
                in: snapshot
            )
        }
        #expect(throws: TmuxOperationImpactError.clientTargetNotConnInteractive(
            fixture.externalInteractiveClient
        )) {
            try analyzer.analyze(.detachClient(externalTarget), in: snapshot)
        }
        #expect(throws: TmuxOperationImpactError.clientTargetDoesNotMatchInitiatingAttachment(
            fixture.currentClient
        )) {
            try analyzer.analyze(
                .selectPane(fixture.sharedPane1, for: currentTarget),
                in: snapshot,
                context: .init(initiatingAttachmentID: "attachment-2")
            )
        }
    }

    @Test("group and linked Window operations expose their complete shared scope")
    func analyzesGroupedAndLinkedSharedEffects() throws {
        let fixture = try ImpactFixture()
        let groupedSnapshot = try fixture.snapshot(groupedSessions: true)
        let analyzer = TmuxOperationImpactAnalyzer()
        let currentTarget = try TmuxClientTarget(fixture.currentClient.targetName)
        let context = TmuxOperationImpactContext(initiatingAttachmentID: "attachment-1")

        let create = try analyzer.analyze(
            .createWindow(in: fixture.session1, name: nil),
            in: groupedSnapshot,
            context: context
        )
        #expect(create.createdEntityKinds == [.window])
        #expect(create.affectedSessionIDs == [fixture.session1, fixture.session2])
        #expect(create.sharedStateEffects == [.sessionWindowTopology])

        let rename = try analyzer.analyze(
            .renameWindow(fixture.sharedWindow, to: TmuxName("renamed")),
            in: groupedSnapshot,
            context: context
        )
        #expect(rename.affectedSessionIDs == [fixture.session1, fixture.session2])
        #expect(rename.affectedWindowIDs == [fixture.sharedWindow])
        #expect(rename.sharedStateEffects == [.windowIdentity])
        #expect(rename.isVisibleAcrossSessions)

        let split = try analyzer.analyze(
            .splitPane(fixture.sharedPane1, orientation: .vertical),
            in: groupedSnapshot,
            context: context
        )
        #expect(split.createdEntityKinds == [.pane])
        #expect(split.affectedSessionIDs == [fixture.session1, fixture.session2])
        #expect(split.affectedWindowIDs == [fixture.sharedWindow])
        #expect(split.affectedPaneIDs == [fixture.sharedPane1])
        #expect(split.sharedStateEffects == [.windowPaneTopology])

        let layout = try analyzer.analyze(
            .applyPaneLayout(fixture.sharedWindow, layout: .tiled),
            in: groupedSnapshot,
            context: context
        )
        #expect(layout.affectedSessionIDs == [fixture.session1, fixture.session2])
        #expect(layout.affectedWindowIDs == [fixture.sharedWindow])
        #expect(layout.affectedPaneIDs == [fixture.sharedPane1, fixture.sharedPane2])
        #expect(layout.sharedStateEffects == [.windowPaneLayout])

        let resize = try analyzer.analyze(
            .resizePane(
                fixture.sharedPane1,
                direction: .right,
                cells: TmuxResizeCellCount(5)
            ),
            in: groupedSnapshot,
            context: context
        )
        #expect(resize.affectedSessionIDs == [fixture.session1, fixture.session2])
        #expect(resize.affectedPaneIDs == [fixture.sharedPane1, fixture.sharedPane2])
        #expect(resize.sharedStateEffects == [.windowPaneLayout])

        let synchronize = try analyzer.analyze(
            .toggleSynchronizePanes(fixture.sharedWindow),
            in: groupedSnapshot,
            context: context
        )
        #expect(synchronize.sharedStateEffects == [.windowOption])

        let zoom = try analyzer.analyze(
            .setPaneZoom(fixture.sharedPane1, zoomed: true),
            in: groupedSnapshot,
            context: context
        )
        #expect(zoom.affectedSessionIDs == [fixture.session1, fixture.session2])
        #expect(zoom.affectedPaneIDs == [fixture.sharedPane1, fixture.sharedPane2])
        #expect(zoom.sharedStateEffects == [.windowZoom])

        let sharedFocus = try analyzer.analyze(
            .selectPane(fixture.sharedPane1, for: currentTarget),
            in: groupedSnapshot,
            context: context
        )
        #expect(sharedFocus.affectedSessionIDs == [fixture.session1, fixture.session2])
        #expect(sharedFocus.sharedStateEffects == [.windowPaneSelection])
        #expect(!sharedFocus.otherInteractiveClientIDs.isEmpty)

        let isolatedFocus = try analyzer.analyze(
            .selectPane(fixture.sharedPane1, for: currentTarget),
            in: groupedSnapshot,
            context: .init(
                initiatingAttachmentID: "attachment-1",
                paneFocusIsolation: .clientLocal
            )
        )
        #expect(isolatedFocus.affectedSessionIDs == [fixture.session1])
        #expect(isolatedFocus.sharedStateEffects == [.clientPaneSelection])
        #expect(isolatedFocus.otherAffectedClientIDs.isEmpty)
        #expect(isolatedFocus.otherInteractiveClientIDs.isEmpty)
    }

    @Test("Kill Session removes its links but destroys only Windows with no remaining link")
    func analyzesKillSessionOrphans() throws {
        let fixture = try ImpactFixture()
        let impact = try TmuxOperationImpactAnalyzer().analyze(
            .killSession(fixture.session1),
            in: fixture.snapshot(),
            context: .init(initiatingAttachmentID: "attachment-1")
        )

        #expect(impact.destroyedSessionIDs == [fixture.session1])
        #expect(impact.affectedWindowIDs == [fixture.sharedWindow, fixture.soloWindow])
        #expect(impact.destroyedWindowIDs == [fixture.soloWindow])
        #expect(impact.destroyedPaneIDs == [fixture.soloPane])
        #expect(impact.removedWindowLinks == [
            .init(sessionID: fixture.session1, windowID: fixture.sharedWindow, index: 0),
            .init(sessionID: fixture.session1, windowID: fixture.soloWindow, index: 1),
        ])
        #expect(!impact.destroyedPaneIDs.contains(fixture.sharedPane1))
        #expect(impact.sharedStateEffects == [
            .clientAttachment,
            .sessionIdentity,
            .sessionWindowTopology,
            .windowPaneTopology,
        ])
    }

    @Test("Kill Window destroys it across links and cascades through windowless Sessions")
    func analyzesKillWindowCascade() throws {
        let fixture = try ImpactFixture()
        let impact = try TmuxOperationImpactAnalyzer().analyze(
            .killWindow(fixture.sharedWindow),
            in: fixture.snapshot(),
            context: .init(initiatingAttachmentID: "attachment-1")
        )

        #expect(impact.affectedSessionIDs == [fixture.session1, fixture.session2])
        #expect(impact.destroyedSessionIDs == [fixture.session2])
        #expect(impact.destroyedWindowIDs == [fixture.sharedWindow])
        #expect(impact.destroyedPaneIDs == [fixture.sharedPane1, fixture.sharedPane2])
        #expect(impact.removedWindowLinks == [
            .init(sessionID: fixture.session1, windowID: fixture.sharedWindow, index: 0),
            .init(sessionID: fixture.session2, windowID: fixture.sharedWindow, index: 0),
        ])
    }

    @Test("closing the final Pane cascades through its Window and final Session")
    func analyzesFinalPaneCascade() throws {
        let fixture = try ImpactFixture()
        let impact = try TmuxOperationImpactAnalyzer().analyze(
            .killPane(fixture.onlyPane),
            in: fixture.snapshot()
        )

        #expect(impact.affectedSessionIDs == [fixture.session3])
        #expect(impact.destroyedSessionIDs == [fixture.session3])
        #expect(impact.destroyedWindowIDs == [fixture.onlyWindow])
        #expect(impact.destroyedPaneIDs == [fixture.onlyPane])
        #expect(impact.removedWindowLinks == [
            .init(sessionID: fixture.session3, windowID: fixture.onlyWindow, index: 0),
        ])
    }

    @Test("client risk excludes the Hub control client and initiating attachment conservatively")
    func projectsOtherClientRisk() throws {
        let fixture = try ImpactFixture()
        let impact = try TmuxOperationImpactAnalyzer().analyze(
            .killSession(fixture.session1),
            in: fixture.snapshot(),
            context: .init(initiatingAttachmentID: "attachment-1")
        )

        #expect(impact.otherAffectedClientIDs == [
            fixture.otherConnClient,
            fixture.externalControlClient,
            fixture.externalInteractiveClient,
            fixture.externalUnknownClient,
        ].sorted(by: TmuxClientID.impactOrder))
        #expect(impact.otherInteractiveClientIDs == [
            fixture.otherConnClient,
            fixture.externalInteractiveClient,
            fixture.externalUnknownClient,
        ].sorted(by: TmuxClientID.impactOrder))
        #expect(!impact.otherAffectedClientIDs.contains(fixture.currentClient))
        #expect(!impact.otherAffectedClientIDs.contains(fixture.hubControlClient))
        #expect(impact.otherAffectedClientIDs.contains(fixture.externalControlClient))
        #expect(impact.otherInteractiveClientIDs.contains(fixture.externalUnknownClient))
    }
}

private struct ImpactFixture {
    let session1: TmuxSessionID
    let session2: TmuxSessionID
    let session3: TmuxSessionID
    let sharedWindow: TmuxWindowID
    let soloWindow: TmuxWindowID
    let onlyWindow: TmuxWindowID
    let sharedPane1: TmuxPaneID
    let sharedPane2: TmuxPaneID
    let soloPane: TmuxPaneID
    let onlyPane: TmuxPaneID
    let currentClient: TmuxClientID
    let otherConnClient: TmuxClientID
    let hubControlClient: TmuxClientID
    let externalControlClient: TmuxClientID
    let externalInteractiveClient: TmuxClientID
    let externalUnknownClient: TmuxClientID
    let session3Client: TmuxClientID
    let instance: TmuxServerInstance
    let observedAt = Date(timeIntervalSince1970: 1_000)

    init() throws {
        session1 = try #require(TmuxSessionID(rawValue: "$1"))
        session2 = try #require(TmuxSessionID(rawValue: "$2"))
        session3 = try #require(TmuxSessionID(rawValue: "$3"))
        sharedWindow = try #require(TmuxWindowID(rawValue: "@1"))
        soloWindow = try #require(TmuxWindowID(rawValue: "@2"))
        onlyWindow = try #require(TmuxWindowID(rawValue: "@3"))
        sharedPane1 = try #require(TmuxPaneID(rawValue: "%1"))
        sharedPane2 = try #require(TmuxPaneID(rawValue: "%2"))
        soloPane = try #require(TmuxPaneID(rawValue: "%3"))
        onlyPane = try #require(TmuxPaneID(rawValue: "%4"))
        currentClient = .init(targetName: "/dev/pts/1", processID: 1, createdAt: 10)
        otherConnClient = .init(targetName: "/dev/pts/2", processID: 2, createdAt: 20)
        hubControlClient = .init(targetName: "/dev/pts/control", processID: 3, createdAt: 30)
        externalControlClient = .init(targetName: "/dev/pts/4", processID: 4, createdAt: 40)
        externalInteractiveClient = .init(targetName: "/dev/pts/5", processID: 5, createdAt: 50)
        externalUnknownClient = .init(targetName: "/dev/pts/6", processID: 6, createdAt: 60)
        session3Client = .init(targetName: "/dev/pts/7", processID: 7, createdAt: 70)
        instance = TmuxServerInstance(
            token: try TmuxServerInstanceToken(
                resolvedSocketPath: "/tmp/tmux/default",
                serverPID: 100,
                serverStartTime: 200
            ),
            version: "tmux 3.5a"
        )
    }

    var clients: [TmuxClientID: TmuxClientSnapshot] {
        [
            currentClient: client(
                id: currentClient,
                sessionID: session1,
                role: .connInteractive(attachmentID: "attachment-1"),
                kind: .interactiveTerminal,
                sizeParticipation: .participating
            ),
            otherConnClient: client(
                id: otherConnClient,
                sessionID: session1,
                role: .connInteractive(attachmentID: "attachment-2"),
                kind: .interactiveTerminal,
                sizeParticipation: .ignored
            ),
            hubControlClient: client(
                id: hubControlClient,
                sessionID: session1,
                role: .connControl(sessionID: session1),
                kind: .controlMode,
                sizeParticipation: .notParticipating
            ),
            externalControlClient: client(
                id: externalControlClient,
                sessionID: session1,
                role: .external,
                kind: .controlMode,
                sizeParticipation: .unknown
            ),
            externalInteractiveClient: client(
                id: externalInteractiveClient,
                sessionID: session1,
                role: .external,
                kind: .interactiveTerminal,
                sizeParticipation: .participating
            ),
            externalUnknownClient: client(
                id: externalUnknownClient,
                sessionID: session1,
                role: .external,
                kind: .unknown,
                sizeParticipation: .unknown
            ),
            session3Client: client(
                id: session3Client,
                sessionID: session3,
                role: .connInteractive(attachmentID: "attachment-3"),
                kind: .interactiveTerminal,
                sizeParticipation: .participating
            ),
        ]
    }

    func client(
        id: TmuxClientID,
        sessionID: TmuxSessionID,
        role: TmuxClientRole,
        kind: TmuxClientKind,
        sizeParticipation: TmuxClientSizeParticipation
    ) -> TmuxClientSnapshot {
        let windowID = sessionID == session3 ? onlyWindow : sharedWindow
        let paneID = sessionID == session3 ? onlyPane : sharedPane1
        return TmuxClientSnapshot(
            id: id,
            sessionID: sessionID,
            currentWindowID: windowID,
            activePaneID: paneID,
            flags: nil,
            role: role,
            kind: kind,
            sizeParticipation: sizeParticipation,
            observedAt: observedAt
        )
    }

    func snapshot(
        groupedSessions: Bool = false,
        clients: [TmuxClientID: TmuxClientSnapshot]? = nil
    ) throws -> TmuxServerSnapshot {
        let groupName = groupedSessions ? "team" : nil
        let sessions: [TmuxSessionID: TmuxSessionSnapshot] = [
            session1: .init(
                id: session1,
                name: "one",
                groupName: groupName,
                currentWindowID: sharedWindow
            ),
            session2: .init(
                id: session2,
                name: "two",
                groupName: groupName,
                currentWindowID: sharedWindow
            ),
            session3: .init(
                id: session3,
                name: "three",
                groupName: nil,
                currentWindowID: onlyWindow
            ),
        ]
        let windows: [TmuxWindowID: TmuxWindowSnapshot] = [
            sharedWindow: .init(
                id: sharedWindow,
                name: "shared",
                layout: "layout",
                isZoomed: false,
                activePaneID: sharedPane1
            ),
            soloWindow: .init(
                id: soloWindow,
                name: "solo",
                layout: nil,
                isZoomed: false,
                activePaneID: soloPane
            ),
            onlyWindow: .init(
                id: onlyWindow,
                name: "only",
                layout: nil,
                isZoomed: false,
                activePaneID: onlyPane
            ),
        ]
        let panes: [TmuxPaneID: TmuxPaneSnapshot] = [
            sharedPane1: pane(id: sharedPane1, windowID: sharedWindow, index: 0),
            sharedPane2: pane(id: sharedPane2, windowID: sharedWindow, index: 1),
            soloPane: pane(id: soloPane, windowID: soloWindow, index: 0),
            onlyPane: pane(id: onlyPane, windowID: onlyWindow, index: 0),
        ]
        return try TmuxServerSnapshot(
            instance: instance,
            sessions: sessions,
            sessionGroups: groupedSessions ? ["team": [session1, session2]] : [:],
            windows: windows,
            panes: panes,
            windowLinks: [
                .init(sessionID: session1, windowID: sharedWindow, index: 0),
                .init(sessionID: session1, windowID: soloWindow, index: 1),
                .init(sessionID: session2, windowID: sharedWindow, index: 0),
                .init(sessionID: session3, windowID: onlyWindow, index: 0),
            ],
            clients: clients ?? self.clients,
            observedAt: observedAt,
            revision: 1,
            impactRevision: 1
        )
    }

    private func pane(id: TmuxPaneID, windowID: TmuxWindowID, index: Int) -> TmuxPaneSnapshot {
        TmuxPaneSnapshot(
            id: id,
            windowID: windowID,
            index: index,
            title: .unavailable,
            currentCommand: .unavailable,
            currentPath: .unavailable,
            size: .init(cols: 80, rows: 24),
            isDead: false
        )
    }
}

private extension TmuxClientID {
    static func impactOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.targetName != rhs.targetName { return lhs.targetName < rhs.targetName }
        if lhs.processID != rhs.processID { return (lhs.processID ?? .min) < (rhs.processID ?? .min) }
        return (lhs.createdAt ?? .min) < (rhs.createdAt ?? .min)
    }
}
