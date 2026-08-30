import ConnKit
@testable import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux snapshot assembler")
struct TmuxSnapshotAssemblerTests {
    @Test("validated records assemble one normalized graph with conservative client ownership")
    func assemblesNormalizedGraph() throws {
        let fixture = try SnapshotAssemblerFixture()
        let observedAt = Date(timeIntervalSince1970: 500)
        let snapshot = try TmuxSnapshotAssembler().assemble(
            fixture.records(),
            scope: fixture.scope(),
            identities: [fixture.interactiveIdentity],
            controlClientID: fixture.controlClientID,
            observedAt: observedAt
        )

        #expect(snapshot.instance.token == fixture.token)
        #expect(snapshot.instance.version == "3.5a")
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.sessionGroups == ["pair": [fixture.session1, fixture.session2]])
        #expect(snapshot.windowLinks.count == 2)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.sessions[fixture.session1]?.currentWindowID == fixture.window)
        #expect(snapshot.sessions[fixture.session2]?.currentWindowID == fixture.window)
        #expect(snapshot.windows[fixture.window]?.activePaneID == fixture.pane)
        #expect(snapshot.panes[fixture.pane]?.title == .init(
            value: "editor\nprimary",
            freshness: .snapshot(observedAt: observedAt)
        ))
        #expect(snapshot.panes[fixture.pane]?.currentCommand == .init(
            value: "nvim",
            freshness: .snapshot(observedAt: observedAt)
        ))
        #expect(snapshot.panes[fixture.pane]?.interaction.alternateOn.value == true)
        #expect(snapshot.panes[fixture.pane]?.interaction.paneInMode.value == true)
        #expect(snapshot.panes[fixture.pane]?.interaction.mode.value == "copy-mode")
        #expect(snapshot.panes[fixture.pane]?.interaction.mouseAnyFlag.value == false)
        #expect(snapshot.panes[fixture.pane]?.interaction.historySize.value == 120)
        #expect(snapshot.panes[fixture.pane]?.interaction.historyLimit.value == 2_000)

        let interactive = try #require(snapshot.clients[fixture.interactiveClientID])
        #expect(interactive.role == .connInteractive(attachmentID: "attachment-1"))
        #expect(interactive.kind == .interactiveTerminal)
        #expect(interactive.flags == [.ignoreSize])
        #expect(interactive.sizeParticipation == .ignored)

        let control = try #require(snapshot.clients[fixture.controlClientID])
        #expect(control.role == .connControl(sessionID: fixture.session1))
        #expect(control.kind == .controlMode)
        #expect(control.sizeParticipation == .notParticipating)

        let external = try #require(snapshot.clients[fixture.externalClientID])
        #expect(external.role == .external)
        #expect(external.kind == .interactiveTerminal)
        #expect(external.flags == [])
        #expect(external.sizeParticipation == .participating)
        #expect(snapshot.revision == 0)
        #expect(snapshot.impactRevision == 0)
    }

    @Test("unavailable legacy metadata remains unavailable instead of being guessed")
    func preservesUnavailableMetadata() throws {
        let fixture = try SnapshotAssemblerFixture()
        let pane = fixture.paneRecord(
            title: .unavailable,
            currentCommand: .unavailable,
            currentPath: .unavailable,
            alternateOn: .unavailable,
            paneInMode: .unavailable,
            paneMode: .unavailable,
            mouseAnyFlag: .unavailable,
            historySize: .unavailable,
            historyLimit: .unavailable
        )
        let external = fixture.externalClientRecord(flags: .unavailable, controlMode: "")
        let snapshot = try TmuxSnapshotAssembler().assemble(
            fixture.records(
                panes: [pane],
                clients: [
                    fixture.interactiveClientRecord(),
                    fixture.controlClientRecord(),
                    external,
                ]
            ),
            scope: fixture.scope(),
            identities: [fixture.interactiveIdentity],
            controlClientID: fixture.controlClientID,
            observedAt: fixture.observedAt
        )

        #expect(snapshot.panes[fixture.pane]?.title == .unavailable)
        #expect(snapshot.panes[fixture.pane]?.currentCommand == .unavailable)
        #expect(snapshot.panes[fixture.pane]?.currentPath == .unavailable)
        #expect(snapshot.panes[fixture.pane]?.interaction == .unavailable)
        #expect(snapshot.clients[fixture.externalClientID]?.flags == nil)
        #expect(snapshot.clients[fixture.externalClientID]?.kind == .unknown)
        #expect(snapshot.clients[fixture.externalClientID]?.sizeParticipation == .unknown)
    }

    @Test("an observed empty pane mode remains fresh while tmux is in normal mode")
    func preservesObservedNormalPaneMode() throws {
        let fixture = try SnapshotAssemblerFixture()
        let snapshot = try fixture.assemble(fixture.records(panes: [fixture.paneRecord(
            alternateOn: .value("0"),
            paneInMode: .value("0"),
            paneMode: .value("")
        )]))

        let interaction = try #require(snapshot.panes[fixture.pane]?.interaction)
        #expect(interaction.mode.value == nil)
        #expect(interaction.mode.freshness == .snapshot(observedAt: fixture.observedAt))

        let state = try TmuxInteractionStateProjector().project(
            snapshot: snapshot,
            identity: fixture.interactiveIdentity,
            attachmentGeneration: 9
        )
        #expect(state.freshness == .snapshot)
        #expect(state.modeCapability == .none)
        #expect(state.historyAvailable)
    }

    @Test("verified Conn ownership survives unavailable kind fields but rejects explicit conflicts")
    func appliesVerifiedOwnershipToUnavailableKinds() throws {
        let fixture = try SnapshotAssemblerFixture()
        let interactive = fixture.interactiveClientRecord(controlMode: "")
        let control = fixture.controlClientRecord(controlMode: "")
        let snapshot = try fixture.assemble(fixture.records(clients: [interactive, control]))

        #expect(snapshot.clients[fixture.interactiveClientID]?.role == .connInteractive(
            attachmentID: "attachment-1"
        ))
        #expect(snapshot.clients[fixture.interactiveClientID]?.kind == .unknown)
        #expect(snapshot.clients[fixture.controlClientID]?.role == .connControl(
            sessionID: fixture.session1
        ))
        #expect(snapshot.clients[fixture.controlClientID]?.kind == .controlMode)

        #expect(throws: TmuxSnapshotAssemblerError.interactiveClientKindMismatch(
            fixture.interactiveClientID
        )) {
            try fixture.assemble(fixture.records(clients: [
                fixture.interactiveClientRecord(controlMode: "1"),
                fixture.controlClientRecord(),
            ]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.controlClientKindMismatch(
            fixture.controlClientID
        )) {
            try fixture.assemble(fixture.records(clients: [
                fixture.interactiveClientRecord(),
                fixture.controlClientRecord(controlMode: "0"),
            ]))
        }
    }

    @Test("server identity must agree at both boundaries and with the requested scope")
    func rejectsServerIdentityChanges() throws {
        let fixture = try SnapshotAssemblerFixture()
        let changed = TmuxDecodedServerIdentityRecord(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: "101",
            serverStartTime: "200",
            version: .value("3.5a")
        )
        #expect(throws: TmuxSnapshotAssemblerError.serverIdentityMismatch) {
            try fixture.assemble(fixture.records(identityAfter: changed))
        }

        let otherToken = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 999,
            serverStartTime: 200
        )
        #expect(throws: TmuxSnapshotAssemblerError.serverTokenMismatch) {
            try TmuxSnapshotAssembler().assemble(
                fixture.records(),
                scope: fixture.scope(token: otherToken),
                identities: [],
                controlClientID: nil,
                observedAt: fixture.observedAt
            )
        }
    }

    @Test("identifiers, numbers and booleans are converted strictly")
    func rejectsMalformedScalars() throws {
        let fixture = try SnapshotAssemblerFixture()

        #expect(throws: TmuxSnapshotAssemblerError.invalidIdentifier(.sessionID)) {
            try fixture.assemble(fixture.records(sessions: [
                .init(id: "1", name: "bad", groupName: "")
            ]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.invalidIdentifier(.windowID)) {
            try fixture.assemble(fixture.records(windows: [
                .init(id: "1", name: "bad", layout: .value("x"), isZoomed: "0")
            ]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.invalidIdentifier(.paneID)) {
            try fixture.assemble(fixture.records(panes: [
                fixture.paneRecord(id: "1")
            ]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.invalidNumber(.windowIndex)) {
            try fixture.assemble(fixture.records(windowLinks: [
                .init(sessionID: "$1", windowID: "@1", index: "-1", isCurrent: "1")
            ]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.invalidNumber(.clientProcessID)) {
            try fixture.assemble(fixture.records(clients: [
                fixture.externalClientRecord(processID: "999999999999999999999")
            ]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.invalidBoolean(.windowActive)) {
            try fixture.assemble(fixture.records(windowLinks: [
                .init(sessionID: "$1", windowID: "@1", index: "0", isCurrent: "true")
            ]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.invalidNumber(.paneHistorySize)) {
            try fixture.assemble(fixture.records(panes: [fixture.paneRecord(
                historySize: .value("-1")
            )]))
        }
    }

    @Test("duplicates are rejected except identical rows for a shared Window")
    func rejectsDuplicateAndConflictingEntities() throws {
        let fixture = try SnapshotAssemblerFixture()
        let session = fixture.sessionRecord1
        #expect(throws: TmuxSnapshotAssemblerError.duplicateSession(fixture.session1)) {
            try fixture.assemble(fixture.records(sessions: [session, session]))
        }

        let conflictingWindow = TmuxDecodedWindowRecord(
            id: "@1",
            name: "different",
            layout: .value("layout"),
            isZoomed: "0"
        )
        #expect(throws: TmuxSnapshotAssemblerError.conflictingWindow(fixture.window)) {
            try fixture.assemble(fixture.records(windows: [fixture.windowRecord, conflictingWindow]))
        }

        let pane = fixture.paneRecord()
        #expect(throws: TmuxSnapshotAssemblerError.duplicatePane(fixture.pane)) {
            try fixture.assemble(fixture.records(panes: [pane, pane]))
        }

        let client = fixture.externalClientRecord()
        #expect(throws: TmuxSnapshotAssemblerError.duplicateClient(fixture.externalClientID)) {
            try fixture.assemble(fixture.records(clients: [client, client]))
        }
    }

    @Test("missing topology and mismatched active Pane ownership fail before publication")
    func rejectsInvalidGraphReferences() throws {
        let fixture = try SnapshotAssemblerFixture()
        #expect(throws: TmuxSnapshotAssemblerError.missingCurrentWindow(fixture.session2)) {
            try fixture.assemble(fixture.records(windowLinks: [fixture.link1]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.missingActivePane(fixture.window)) {
            try fixture.assemble(fixture.records(panes: [
                fixture.paneRecord(isActive: "0")
            ]))
        }

        let unknownSessionClient = TmuxDecodedClientRecord(
            targetName: "/dev/ttys099",
            tty: .value("/dev/ttys099"),
            processID: "599",
            createdAt: "1099",
            sessionID: "$99",
            currentWindowID: "@1",
            activePaneID: "%1",
            flags: .value(""),
            controlMode: "0"
        )
        #expect(throws: TmuxSnapshotValidationError.missingClientSession(
            clientID: .init(targetName: "/dev/ttys099", processID: 599, createdAt: 1099),
            sessionID: try #require(TmuxSessionID(rawValue: "$99"))
        )) {
            try TmuxSnapshotAssembler().assemble(
                fixture.records(clients: [unknownSessionClient]),
                scope: fixture.scope(),
                identities: [],
                controlClientID: nil,
                observedAt: fixture.observedAt
            )
        }

        let pane2 = try #require(TmuxPaneID(rawValue: "%2"))
        let mismatchedClient = TmuxDecodedClientRecord(
            targetName: "/dev/ttys098",
            tty: .value("/dev/ttys098"),
            processID: "598",
            createdAt: "1098",
            sessionID: "$1",
            currentWindowID: "@1",
            activePaneID: pane2.rawValue,
            flags: .value(""),
            controlMode: "0"
        )
        #expect(throws: TmuxSnapshotValidationError.missingClientActivePane(
            clientID: .init(targetName: "/dev/ttys098", processID: 598, createdAt: 1098),
            paneID: pane2
        )) {
            try TmuxSnapshotAssembler().assemble(
                fixture.records(clients: [mismatchedClient]),
                scope: fixture.scope(),
                identities: [],
                controlClientID: nil,
                observedAt: fixture.observedAt
            )
        }
    }

    @Test("client flags and ownership claims fail closed on malformed or conflicting facts")
    func rejectsInvalidClientClassification() throws {
        let fixture = try SnapshotAssemblerFixture()
        #expect(throws: TmuxSnapshotAssemblerError.invalidClientFlags) {
            try fixture.assemble(fixture.records(clients: [
                fixture.externalClientRecord(flags: .value("attached,,ignore-size"))
            ]))
        }
        #expect(throws: TmuxSnapshotAssemblerError.invalidClientFlags) {
            try fixture.assemble(fixture.records(clients: [
                fixture.externalClientRecord(flags: .value("attached bad"))
            ]))
        }

        let duplicateClaim = TmuxControlInteractiveIdentity(
            attachmentID: "attachment-2",
            clientID: fixture.interactiveClientID,
            requestedSessionID: fixture.session1
        )
        #expect(throws: TmuxSnapshotAssemblerError.conflictingClientOwnership(
            fixture.interactiveClientID
        )) {
            try TmuxSnapshotAssembler().assemble(
                fixture.records(),
                scope: fixture.scope(),
                identities: [fixture.interactiveIdentity, duplicateClaim],
                controlClientID: fixture.controlClientID,
                observedAt: fixture.observedAt
            )
        }

        #expect(throws: TmuxSnapshotAssemblerError.conflictingClientOwnership(
            fixture.interactiveClientID
        )) {
            try TmuxSnapshotAssembler().assemble(
                fixture.records(),
                scope: fixture.scope(),
                identities: [fixture.interactiveIdentity],
                controlClientID: fixture.interactiveClientID,
                observedAt: fixture.observedAt
            )
        }

        let missingControl = TmuxClientID(
            targetName: "client-999",
            processID: 999,
            createdAt: 1999
        )
        #expect(throws: TmuxSnapshotAssemblerError.controlClientMissing(missingControl)) {
            try TmuxSnapshotAssembler().assemble(
                fixture.records(),
                scope: fixture.scope(),
                identities: [],
                controlClientID: missingControl,
                observedAt: fixture.observedAt
            )
        }
    }

    @Test("an owned interactive client keeps its attachment identity after switching sessions")
    func preservesOwnershipAcrossSessionSwitch() throws {
        let fixture = try SnapshotAssemblerFixture()
        let snapshot = try fixture.assemble(fixture.records(clients: [
            fixture.interactiveClientRecord(sessionID: fixture.session2.rawValue),
            fixture.controlClientRecord(),
            fixture.externalClientRecord(),
        ]))

        #expect(snapshot.clients[fixture.interactiveClientID]?.sessionID == fixture.session2)
        #expect(
            snapshot.clients[fixture.interactiveClientID]?.role
                == .connInteractive(attachmentID: "attachment-1")
        )
    }
}

private struct SnapshotAssemblerFixture {
    let session1: TmuxSessionID
    let session2: TmuxSessionID
    let window: TmuxWindowID
    let pane: TmuxPaneID
    let token: TmuxServerInstanceToken
    let interactiveClientID: TmuxClientID
    let controlClientID: TmuxClientID
    let externalClientID: TmuxClientID
    let observedAt = Date(timeIntervalSince1970: 500)

    init() throws {
        session1 = try #require(TmuxSessionID(rawValue: "$1"))
        session2 = try #require(TmuxSessionID(rawValue: "$2"))
        window = try #require(TmuxWindowID(rawValue: "@1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
        interactiveClientID = .init(
            targetName: "/dev/ttys001",
            processID: 501,
            createdAt: 1001
        )
        controlClientID = .init(
            targetName: "client-502",
            processID: 502,
            createdAt: 1002
        )
        externalClientID = .init(
            targetName: "/dev/ttys002",
            processID: 503,
            createdAt: 1003
        )
    }

    var interactiveIdentity: TmuxControlInteractiveIdentity {
        .init(
            attachmentID: "attachment-1",
            clientID: interactiveClientID,
            requestedSessionID: session1
        )
    }

    var identity: TmuxDecodedServerIdentityRecord {
        .init(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: "100",
            serverStartTime: "200",
            version: .value("3.5a")
        )
    }

    var sessionRecord1: TmuxDecodedSessionRecord {
        .init(id: "$1", name: "alpha", groupName: "pair")
    }

    var sessionRecord2: TmuxDecodedSessionRecord {
        .init(id: "$2", name: "beta", groupName: "pair")
    }

    var link1: TmuxDecodedWindowLinkRecord {
        .init(sessionID: "$1", windowID: "@1", index: "0", isCurrent: "1")
    }

    var link2: TmuxDecodedWindowLinkRecord {
        .init(sessionID: "$2", windowID: "@1", index: "0", isCurrent: "1")
    }

    var windowRecord: TmuxDecodedWindowRecord {
        .init(
            id: "@1",
            name: "editor",
            layout: .value("layout"),
            isZoomed: "0"
        )
    }

    func paneRecord(
        id: String = "%1",
        title: TmuxDecodedSnapshotText = .value("editor\nprimary"),
        currentCommand: TmuxDecodedSnapshotText = .value("nvim"),
        currentPath: TmuxDecodedSnapshotText = .value("/repo"),
        alternateOn: TmuxDecodedSnapshotText = .value("1"),
        paneInMode: TmuxDecodedSnapshotText = .value("1"),
        paneMode: TmuxDecodedSnapshotText = .value("copy-mode"),
        mouseAnyFlag: TmuxDecodedSnapshotText = .value("0"),
        historySize: TmuxDecodedSnapshotText = .value("120"),
        historyLimit: TmuxDecodedSnapshotText = .value("2000"),
        isActive: String = "1"
    ) -> TmuxDecodedPaneRecord {
        .init(
            id: id,
            windowID: "@1",
            index: "0",
            title: title,
            currentCommand: currentCommand,
            currentPath: currentPath,
            alternateOn: alternateOn,
            paneInMode: paneInMode,
            paneMode: paneMode,
            mouseAnyFlag: mouseAnyFlag,
            historySize: historySize,
            historyLimit: historyLimit,
            width: "120",
            height: "40",
            isDead: "0",
            isActive: isActive
        )
    }

    func interactiveClientRecord(
        controlMode: String = "0",
        sessionID: String = "$1"
    ) -> TmuxDecodedClientRecord {
        .init(
            targetName: interactiveClientID.targetName,
            tty: .value("/dev/ttys001"),
            processID: "501",
            createdAt: "1001",
            sessionID: sessionID,
            currentWindowID: "@1",
            activePaneID: "%1",
            flags: .value("attached,focused,UTF-8,ignore-size"),
            controlMode: controlMode
        )
    }

    func controlClientRecord(controlMode: String = "1") -> TmuxDecodedClientRecord {
        .init(
            targetName: controlClientID.targetName,
            tty: .value(""),
            processID: "502",
            createdAt: "1002",
            sessionID: "$1",
            currentWindowID: "@1",
            activePaneID: "%1",
            flags: .value("attached,control-mode,no-output"),
            controlMode: controlMode
        )
    }

    func externalClientRecord(
        processID: String = "503",
        flags: TmuxDecodedSnapshotText = .value(""),
        controlMode: String = "0"
    ) -> TmuxDecodedClientRecord {
        .init(
            targetName: externalClientID.targetName,
            tty: .value("/dev/ttys002"),
            processID: processID,
            createdAt: "1003",
            sessionID: "$2",
            currentWindowID: "@1",
            activePaneID: "%1",
            flags: flags,
            controlMode: controlMode
        )
    }

    func records(
        identityAfter: TmuxDecodedServerIdentityRecord? = nil,
        sessions: [TmuxDecodedSessionRecord]? = nil,
        windowLinks: [TmuxDecodedWindowLinkRecord]? = nil,
        windows: [TmuxDecodedWindowRecord]? = nil,
        panes: [TmuxDecodedPaneRecord]? = nil,
        clients: [TmuxDecodedClientRecord]? = nil
    ) -> TmuxDecodedSnapshotRecords {
        .init(
            identityBefore: identity,
            identityAfter: identityAfter ?? identity,
            sessions: sessions ?? [sessionRecord1, sessionRecord2],
            windowLinks: windowLinks ?? [link1, link2],
            windows: windows ?? [windowRecord, windowRecord],
            panes: panes ?? [paneRecord()],
            clients: clients ?? [
                interactiveClientRecord(),
                controlClientRecord(),
                externalClientRecord(),
            ]
        )
    }

    func scope(token: TmuxServerInstanceToken? = nil) throws -> TmuxOperationScope {
        try TmuxOperationScope(
            connectionIdentity: SSHConnectionIdentity(host: Host(
                id: "host-1",
                name: "Server",
                address: "server.example",
                username: "root"
            )),
            configurationKey: "profile-1",
            instanceToken: token ?? self.token,
            generation: 7
        )
    }

    func assemble(_ records: TmuxDecodedSnapshotRecords) throws -> TmuxServerSnapshot {
        try TmuxSnapshotAssembler().assemble(
            records,
            scope: scope(),
            identities: [interactiveIdentity],
            controlClientID: controlClientID,
            observedAt: observedAt
        )
    }
}
