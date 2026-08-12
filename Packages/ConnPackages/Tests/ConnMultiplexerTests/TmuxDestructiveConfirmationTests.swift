import ConnKit
import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux destructive confirmation")
struct TmuxDestructiveConfirmationTests {
    @Test("preparation requires destructive semantics, matching scope and fresh topology")
    func requiresFreshDestructiveImpact() throws {
        let fixture = try ConfirmationFixture()
        let policy = try TmuxDestructiveConfirmationPolicy(
            maximumSnapshotAge: 30,
            claimLifetime: 10
        )
        let guarder = TmuxDestructiveConfirmationGuard(policy: policy)
        let now = Date(timeIntervalSince1970: 110)
        let scope = try fixture.scope()
        let snapshot = try fixture.snapshot()

        #expect(throws: TmuxDestructiveConfirmationError.operationIsNotDestructive) {
            try guarder.prepare(
                TmuxOperationRequest(
                    scope: scope,
                    operation: .renameSession(fixture.session1, to: TmuxName("renamed"))
                ),
                snapshot: snapshot,
                now: now
            )
        }

        let otherTokenScope = try fixture.scope(token: fixture.otherToken)
        #expect(throws: TmuxDestructiveConfirmationError.scopeInstanceMismatch) {
            try guarder.prepare(
                fixture.killSessionRequest(scope: otherTokenScope),
                snapshot: snapshot,
                now: now
            )
        }

        #expect(throws: TmuxDestructiveConfirmationError.snapshotRefreshRequired) {
            try guarder.prepare(
                fixture.killSessionRequest(scope: scope),
                snapshot: fixture.snapshot(observedAt: Date(timeIntervalSince1970: 79)),
                now: now
            )
        }

        #expect(throws: TmuxDestructiveConfirmationError.clientTopologyRefreshRequired(
            fixture.externalClientA
        )) {
            try guarder.prepare(
                fixture.killSessionRequest(scope: scope),
                snapshot: fixture.snapshot(
                    observedAt: now,
                    clientObservedAt: Date(timeIntervalSince1970: 79)
                ),
                context: .init(initiatingAttachmentID: "attachment-1"),
                now: now
            )
        }

        let prepared = try guarder.prepare(
            fixture.killSessionRequest(scope: scope),
            snapshot: snapshot,
            context: .init(initiatingAttachmentID: "attachment-1"),
            now: now
        )
        #expect(prepared.request == fixture.killSessionRequest(scope: scope))
        #expect(prepared.claim.scope == scope)
        #expect(prepared.claim.impactRevision == snapshot.impactRevision)
        #expect(prepared.claim.expiresAt == Date(timeIntervalSince1970: 120))
        #expect(prepared.impact.destroyedSessionIDs == [fixture.session1])
    }

    @Test("confirmation policy rejects non-finite, non-positive and excessive durations")
    func validatesPolicyBounds() {
        for (snapshotAge, lifetime) in [
            (0.0, 10.0),
            (10.0, -1.0),
            (.infinity, 10.0),
            (10.0, .nan),
            (301.0, 10.0),
            (10.0, 301.0),
        ] {
            #expect(throws: TmuxDestructiveConfirmationError.invalidPolicy) {
                try TmuxDestructiveConfirmationPolicy(
                    maximumSnapshotAge: snapshotAge,
                    claimLifetime: lifetime
                )
            }
        }
    }

    @Test("claim cannot cross expiration, scope, operation, context or impact revision")
    func rejectsEveryStaleConfirmationBoundary() throws {
        let fixture = try ConfirmationFixture()
        let guarder = TmuxDestructiveConfirmationGuard(policy: try .init(
            maximumSnapshotAge: 30,
            claimLifetime: 10
        ))
        let scope = try fixture.scope()
        let request = fixture.killSessionRequest(scope: scope)
        let snapshot = try fixture.snapshot()
        let context = TmuxOperationImpactContext(initiatingAttachmentID: "attachment-1")
        let prepared = try guarder.prepare(
            request,
            snapshot: snapshot,
            context: context,
            now: Date(timeIntervalSince1970: 110)
        )

        #expect(throws: TmuxDestructiveConfirmationError.staleConfirmation) {
            try guarder.validate(
                prepared.claim,
                for: request,
                snapshot: snapshot,
                context: context,
                now: prepared.claim.expiresAt
            )
        }

        let changedIdentityScope = try fixture.scope(hostID: "host-2")
        let changedProfileScope = try fixture.scope(profileID: "profile-2")
        let changedGenerationScope = try fixture.scope(generation: 8)
        for changedScope in [changedIdentityScope, changedProfileScope, changedGenerationScope] {
            #expect(throws: TmuxDestructiveConfirmationError.staleConfirmation) {
                try guarder.validate(
                    prepared.claim,
                    for: fixture.killSessionRequest(scope: changedScope),
                    snapshot: snapshot,
                    context: context,
                    now: Date(timeIntervalSince1970: 111)
                )
            }
        }

        let otherScope = try fixture.scope(token: fixture.otherToken)
        #expect(throws: TmuxDestructiveConfirmationError.staleConfirmation) {
            try guarder.validate(
                prepared.claim,
                for: fixture.killSessionRequest(scope: otherScope),
                snapshot: fixture.snapshot(token: fixture.otherToken),
                context: context,
                now: Date(timeIntervalSince1970: 111)
            )
        }

        #expect(throws: TmuxDestructiveConfirmationError.staleConfirmation) {
            try guarder.validate(
                prepared.claim,
                for: TmuxOperationRequest(scope: scope, operation: .killPane(fixture.pane1)),
                snapshot: snapshot,
                context: context,
                now: Date(timeIntervalSince1970: 111)
            )
        }
        #expect(throws: TmuxDestructiveConfirmationError.staleConfirmation) {
            try guarder.validate(
                prepared.claim,
                for: request,
                snapshot: snapshot,
                context: .init(initiatingAttachmentID: nil),
                now: Date(timeIntervalSince1970: 111)
            )
        }
        #expect(throws: TmuxDestructiveConfirmationError.staleConfirmation) {
            try guarder.validate(
                prepared.claim,
                for: request,
                snapshot: fixture.snapshot(revision: 2, impactRevision: 2),
                context: context,
                now: Date(timeIntervalSince1970: 111)
            )
        }
    }

    @Test("structural digest detects a different client even when counts stay equal")
    func detectsSameCountClientReplacement() throws {
        let fixture = try ConfirmationFixture()
        let guarder = TmuxDestructiveConfirmationGuard(policy: try .init(
            maximumSnapshotAge: 30,
            claimLifetime: 10
        ))
        let scope = try fixture.scope()
        let request = fixture.killSessionRequest(scope: scope)
        let context = TmuxOperationImpactContext(initiatingAttachmentID: "attachment-1")
        let prepared = try guarder.prepare(
            request,
            snapshot: fixture.snapshot(),
            context: context,
            now: Date(timeIntervalSince1970: 110)
        )

        #expect(throws: TmuxDestructiveConfirmationError.staleConfirmation) {
            try guarder.validate(
                prepared.claim,
                for: request,
                snapshot: fixture.snapshot(externalClientID: fixture.externalClientB),
                context: context,
                now: Date(timeIntervalSince1970: 111)
            )
        }
    }

    @Test("metadata and observation refresh do not invalidate the same operational impact")
    func keepsClaimStableAcrossMetadataRefresh() throws {
        let fixture = try ConfirmationFixture()
        let guarder = TmuxDestructiveConfirmationGuard(policy: try .init(
            maximumSnapshotAge: 30,
            claimLifetime: 10
        ))
        let scope = try fixture.scope()
        let request = fixture.killSessionRequest(scope: scope)
        let context = TmuxOperationImpactContext(initiatingAttachmentID: "attachment-1")
        let prepared = try guarder.prepare(
            request,
            snapshot: fixture.snapshot(),
            context: context,
            now: Date(timeIntervalSince1970: 110)
        )
        let refreshedAt = Date(timeIntervalSince1970: 115)
        let refreshed = try fixture.snapshot(
            observedAt: refreshedAt,
            clientObservedAt: refreshedAt,
            revision: 2,
            impactRevision: 1,
            paneTitle: "new title"
        )

        let validated = try guarder.validate(
            prepared.claim,
            for: request,
            snapshot: refreshed,
            context: context,
            now: refreshedAt
        )
        #expect(validated.request == request)
        #expect(validated.confirmationNonce == prepared.claim.nonce)
        #expect(validated.impact == prepared.impact)
    }
}

private struct ConfirmationFixture {
    let session1: TmuxSessionID
    let session2: TmuxSessionID
    let window1: TmuxWindowID
    let window2: TmuxWindowID
    let pane1: TmuxPaneID
    let pane2: TmuxPaneID
    let currentClient: TmuxClientID
    let externalClientA: TmuxClientID
    let externalClientB: TmuxClientID
    let token: TmuxServerInstanceToken
    let otherToken: TmuxServerInstanceToken
    let observedAt = Date(timeIntervalSince1970: 100)

    init() throws {
        session1 = try #require(TmuxSessionID(rawValue: "$1"))
        session2 = try #require(TmuxSessionID(rawValue: "$2"))
        window1 = try #require(TmuxWindowID(rawValue: "@1"))
        window2 = try #require(TmuxWindowID(rawValue: "@2"))
        pane1 = try #require(TmuxPaneID(rawValue: "%1"))
        pane2 = try #require(TmuxPaneID(rawValue: "%2"))
        currentClient = .init(targetName: "/dev/pts/1", processID: 1, createdAt: 10)
        externalClientA = .init(targetName: "/dev/pts/2", processID: 2, createdAt: 20)
        externalClientB = .init(targetName: "/dev/pts/3", processID: 3, createdAt: 30)
        token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
        otherToken = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 101,
            serverStartTime: 201
        )
    }

    func scope(
        hostID: String = "host-1",
        profileID: String = "profile-1",
        token: TmuxServerInstanceToken? = nil,
        generation: UInt64 = 7
    ) throws -> TmuxOperationScope {
        try TmuxOperationScope(
            connectionIdentity: SSHConnectionIdentity(host: Host(
                id: hostID,
                name: "Server",
                address: "server.example",
                username: "root"
            )),
            profileID: profileID,
            instanceToken: token ?? self.token,
            generation: generation
        )
    }

    func killSessionRequest(scope: TmuxOperationScope) -> TmuxOperationRequest {
        TmuxOperationRequest(scope: scope, operation: .killSession(session1))
    }

    func snapshot(
        token: TmuxServerInstanceToken? = nil,
        observedAt: Date? = nil,
        clientObservedAt: Date? = nil,
        externalClientID: TmuxClientID? = nil,
        revision: UInt64 = 1,
        impactRevision: UInt64 = 1,
        paneTitle: String = "title"
    ) throws -> TmuxServerSnapshot {
        let snapshotObservedAt = observedAt ?? self.observedAt
        let topologyObservedAt = clientObservedAt ?? self.observedAt
        let externalID = externalClientID ?? externalClientA
        let current = TmuxClientSnapshot(
            id: currentClient,
            sessionID: session1,
            currentWindowID: window1,
            activePaneID: pane1,
            flags: [],
            role: .connInteractive(attachmentID: "attachment-1"),
            kind: .interactiveTerminal,
            sizeParticipation: .participating,
            observedAt: topologyObservedAt
        )
        let external = TmuxClientSnapshot(
            id: externalID,
            sessionID: session1,
            currentWindowID: window1,
            activePaneID: pane1,
            flags: nil,
            role: .external,
            kind: .unknown,
            sizeParticipation: .unknown,
            observedAt: topologyObservedAt
        )
        return try TmuxServerSnapshot(
            instance: .init(token: token ?? self.token, version: "tmux 3.5a"),
            sessions: [
                session1: .init(id: session1, name: "one", groupName: nil, currentWindowID: window1),
                session2: .init(id: session2, name: "two", groupName: nil, currentWindowID: window2),
            ],
            sessionGroups: [:],
            windows: [
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
                    activePaneID: pane2
                ),
            ],
            panes: [
                pane1: pane(
                    id: pane1,
                    windowID: window1,
                    title: paneTitle,
                    observedAt: snapshotObservedAt
                ),
                pane2: pane(
                    id: pane2,
                    windowID: window2,
                    title: "other",
                    observedAt: snapshotObservedAt
                ),
            ],
            windowLinks: [
                .init(sessionID: session1, windowID: window1, index: 0),
                .init(sessionID: session2, windowID: window2, index: 0),
            ],
            clients: [currentClient: current, externalID: external],
            observedAt: snapshotObservedAt,
            revision: revision,
            impactRevision: impactRevision
        )
    }

    private func pane(
        id: TmuxPaneID,
        windowID: TmuxWindowID,
        title: String,
        observedAt: Date
    ) -> TmuxPaneSnapshot {
        TmuxPaneSnapshot(
            id: id,
            windowID: windowID,
            index: 0,
            title: .init(value: title, freshness: .snapshot(observedAt: observedAt)),
            currentCommand: .unavailable,
            currentPath: .unavailable,
            size: .init(cols: 80, rows: 24),
            isDead: false
        )
    }
}
