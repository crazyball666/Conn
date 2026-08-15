import ConnKit
@testable import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("tmux terminal interaction")
struct TmuxInteractionTests {
    @Test("copy and view modes are scrollable while choose modes remain key-driven")
    func classifiesDocumentedModesByCapability() {
        for mode in ["copy-mode", "copy-mode-vi", "view-mode"] {
            #expect(TmuxInteractionModeClassifier.classify(
                paneInMode: true,
                mode: mode
            ) == .scrollable)
        }
        for mode in ["choose-tree", "choose-buffer", "client-mode", "tree-mode"] {
            #expect(TmuxInteractionModeClassifier.classify(
                paneInMode: true,
                mode: mode
            ) == .keyDriven)
        }
        #expect(TmuxInteractionModeClassifier.classify(
            paneInMode: true,
            mode: "future-mode"
        ) == .unsupported)
        #expect(TmuxInteractionModeClassifier.classify(
            paneInMode: false,
            mode: "copy-mode"
        ) == .none)
    }

    @Test("missing mode identity fails closed and never guesses from the command name")
    func classifiesMissingModeConservatively() {
        #expect(TmuxInteractionModeClassifier.classify(
            paneInMode: true,
            mode: nil
        ) == .unsupported)
        #expect(TmuxInteractionModeClassifier.classify(
            paneInMode: nil,
            mode: "copy-mode"
        ) == .unsupported)
    }

    @Test("projection keeps stale provider observations stale and resolves the verified active pane")
    func projectsVerifiedStateAndFreshness() throws {
        let fixture = try InteractionFixture()
        let live = try TmuxInteractionStateProjector().project(
            snapshot: fixture.snapshot(freshness: .liveSubscription(observedAt: fixture.now)),
            identity: fixture.identity,
            attachmentGeneration: 9
        )
        #expect(live.freshness == .live)
        #expect(live.isAlternateBuffer == false)
        #expect(live.modeCapability == .scrollable)
        #expect(live.providerModeID == "copy-mode")
        #expect(live.historyAvailable)

        let stale = try TmuxInteractionStateProjector().project(
            snapshot: fixture.snapshot(freshness: .stale(lastObservedAt: fixture.now)),
            identity: fixture.identity,
            attachmentGeneration: 9
        )
        #expect(stale.freshness == .stale)
        #expect(stale.modeCapability == .scrollable)
    }

    @Test("projection rejects a client that no longer owns the requested session or active pane")
    func rejectsIdentityDrift() throws {
        let fixture = try InteractionFixture()
        let wrongIdentity = TmuxControlInteractiveIdentity(
            attachmentID: fixture.identity.attachmentID,
            clientID: .init(targetName: "/dev/pts/other", processID: 999, createdAt: 999),
            requestedSessionID: fixture.session
        )
        #expect(throws: TmuxInteractionError.clientUnavailable) {
            try TmuxInteractionStateProjector().project(
                snapshot: fixture.snapshot(freshness: .snapshot(observedAt: fixture.now)),
                identity: wrongIdentity,
                attachmentGeneration: 9
            )
        }
    }

    @Test("history parsing strips terminal side effects and returns immutable bounded lines")
    func sanitizesCapturedHistory() throws {
        let bytes = Data([
            0x61, 0x1B, 0x5D, 0x35, 0x32, 0x3B, 0x63, 0x3B, 0x63, 0x32, 0x56, 0x6A, 0x63, 0x6D,
            0x56, 0x30, 0x07, 0x62, 0x0D, 0x0A,
            0x1B, 0x50, 0x71, 0x75, 0x65, 0x72, 0x79, 0x1B, 0x5C,
            0x63, 0x09, 0x64, 0x00, 0xFF,
        ])
        let parsed = TmuxHistoryCaptureParser().parse(
            bytes,
            maximumLines: 10,
            maximumBytes: 1_024
        )

        #expect(parsed.lines.map(\.text) == ["ab", "c\td�"])
        #expect(parsed.lines.allSatisfy { !$0.text.contains("secret") })
        #expect(!parsed.isTruncated)

        var mutable = bytes
        mutable.removeAll()
        #expect(parsed.lines.map(\.text) == ["ab", "c\td�"])
    }

    @Test("history parsing keeps the newest complete lines and makes truncation explicit")
    func boundsCapturedHistory() {
        let parsed = TmuxHistoryCaptureParser().parse(
            Data("one\ntwo\nthree\nfour".utf8),
            maximumLines: 2,
            maximumBytes: 13
        )

        #expect(parsed.lines.map(\.text) == ["two", "three"])
        #expect(parsed.isTruncated)
        #expect(parsed.byteCount == 13)
    }
}

private struct InteractionFixture {
    let now = Date(timeIntervalSince1970: 900)
    let token: TmuxServerInstanceToken
    let session: TmuxSessionID
    let window: TmuxWindowID
    let pane: TmuxPaneID
    let client: TmuxClientID

    init() throws {
        token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
        session = try #require(TmuxSessionID(rawValue: "$1"))
        window = try #require(TmuxWindowID(rawValue: "@1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        client = .init(targetName: "/dev/pts/1", processID: 101, createdAt: 1_000)
    }

    var identity: TmuxControlInteractiveIdentity {
        .init(attachmentID: "attachment-1", clientID: client, requestedSessionID: session)
    }

    var target: PersistentTerminalInteractionTarget {
        .init(providerID: "tmux", workspaceID: session.rawValue, targetID: pane.rawValue)
    }

    func snapshot(freshness: TmuxMetadataFreshness) throws -> TmuxServerSnapshot {
        return try TmuxServerSnapshot(
            instance: .init(token: token, version: "3.5a"),
            sessions: [session: .init(
                id: session, name: "main", groupName: nil, currentWindowID: window
            )],
            sessionGroups: [:],
            windows: [window: .init(
                id: window, name: "window", layout: nil, isZoomed: false, activePaneID: pane
            )],
            panes: [pane: .init(
                id: pane,
                windowID: window,
                index: 0,
                title: .unavailable,
                currentCommand: .unavailable,
                currentPath: .unavailable,
                interaction: .init(
                    alternateOn: observed(false, freshness: freshness),
                    paneInMode: observed(true, freshness: freshness),
                    mode: observed("copy-mode", freshness: freshness),
                    mouseAnyFlag: observed(false, freshness: freshness),
                    historySize: observed(120, freshness: freshness),
                    historyLimit: observed(2_000, freshness: freshness)
                ),
                size: .init(cols: 80, rows: 24),
                isDead: false
            )],
            windowLinks: [.init(sessionID: session, windowID: window, index: 0)],
            clients: [client: .init(
                id: client,
                sessionID: session,
                currentWindowID: window,
                activePaneID: pane,
                flags: [.ignoreSize, .activePane],
                role: .connInteractive(attachmentID: "attachment-1"),
                kind: .interactiveTerminal,
                sizeParticipation: .ignored,
                observedAt: now
            )],
            observedAt: now,
            revision: 4,
            impactRevision: 0
        )
    }

    private func observed<T: Sendable & Equatable>(
        _ value: T,
        freshness: TmuxMetadataFreshness
    ) -> TmuxObservedValue<T> {
        TmuxObservedValue(value: value, freshness: freshness)
    }
}
