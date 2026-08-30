import Testing
import ConnMultiplexer
@testable import ConnTerminal

@Suite("Terminal interaction routing")
struct TerminalInteractionTests {
    private let router = TerminalScrollRouter()

    @Test("router follows capability priority from selection to local history")
    func exhaustivePriority() {
        let normal = protocolState()

        #expect(router.route(input(mode: .selecting, protocolState: normal)).kind == .selection)
        #expect(router.route(input(mode: .pointer, protocolState: normal)).kind == .pointer)

        let mouse = protocolState(mouseTracking: .pressAndRelease)
        #expect(router.route(input(protocolState: mouse)).kind == .remoteMouse)

        #expect(router.route(input(persistent: persistent(mode: .scrollable))).kind == .providerScrollableMode)
        #expect(router.route(input(persistent: persistent(mode: .keyDriven))).kind == .providerKeyDrivenMode)
        #expect(router.route(input(persistent: persistent(mode: .unsupported))).kind == .providerUnsupportedBoundary)
        #expect(router.route(input(persistent: persistent(isAlternateBuffer: true))).kind == .providerAlternateKeys)
        #expect(router.route(input(persistent: persistent(historyAvailable: true))).kind == .providerHistory)

        #expect(router.route(input(protocolState: protocolState(isAlternateBuffer: true))).kind == .plainAlternateKeys)
        #expect(router.route(input(protocolState: normal)).kind == .localNormalBuffer)
        #expect(router.route(input(protocolState: normal, localHistoryAvailable: false)).kind == .boundary)
    }

    @Test("remote mouse outranks stale provider state")
    func remoteMouseBeforeProviderRefresh() {
        let decision = router.route(input(
            protocolState: protocolState(mouseTracking: .allMotion),
            persistent: persistent(freshness: .stale)
        ))

        #expect(decision.kind == .remoteMouse)
    }

    @Test("provider-owned history refreshes before entering mode when history is unavailable")
    func providerOwnedHistoryRefreshesBeforeEnteringMode() {
        let decision = router.route(input(
            persistent: persistent(
                historyOwnership: .provider,
                historyAvailable: false
            )
        ))

        #expect(decision.kind == .resolvePersistentState)
    }

    @Test("stale provider state resolves once before provider routing")
    func staleProviderStateResolves() {
        let decision = router.route(input(persistent: persistent(freshness: .stale)))

        #expect(decision.kind == .resolvePersistentState)
    }

    @Test("route token ignores observational revisions and non-scroll protocol changes")
    func routeTokenIgnoresNonScrollChanges() throws {
        let original = input(
            protocolState: protocolState(
                revision: 7,
                bracketedPasteEnabled: false,
                focusReportingEnabled: false,
                synchronizedOutputEnabled: false,
                applicationCursorEnabled: false
            ),
            persistent: persistent(revision: 11, historyAvailable: true),
            attachmentGeneration: 3
        )
        let token = try #require(router.route(original).token)

        #expect(token.matches(original))
        #expect(token.matches(input(
            protocolState: protocolState(
                revision: 8,
                bracketedPasteEnabled: true,
                focusReportingEnabled: true,
                synchronizedOutputEnabled: true,
                applicationCursorEnabled: true
            ),
            persistent: persistent(revision: 12, historyAvailable: true),
            attachmentGeneration: 3
        )))
    }

    @Test("route token rejects every scroll-routing change")
    func routeTokenRejectsRoutingChanges() throws {
        let original = input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(
                revision: 11,
                historyAvailable: true,
                targetID: "pane-a"
            ),
            attachmentGeneration: 3
        )
        let token = try #require(router.route(original).token)

        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(
                revision: 11,
                historyAvailable: true,
                targetID: "pane-a"
            ),
            attachmentGeneration: 4
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7, mouseTracking: .allMotion),
            persistent: persistent(revision: 11, historyAvailable: true, targetID: "pane-a"),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7, isAlternateBuffer: true),
            persistent: persistent(revision: 11, historyAvailable: true, targetID: "pane-a"),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7, alternateScrollEnabled: false),
            persistent: persistent(revision: 11, historyAvailable: true, targetID: "pane-a"),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7, columns: 81),
            persistent: persistent(revision: 11, historyAvailable: true, targetID: "pane-a"),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7, rows: 25),
            persistent: persistent(revision: 11, historyAvailable: true, targetID: "pane-a"),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(
                revision: 11,
                freshness: .stale,
                historyAvailable: true,
                targetID: "pane-a"
            ),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(
                revision: 11,
                isAlternateBuffer: true,
                historyAvailable: true,
                targetID: "pane-a"
            ),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(
                revision: 11,
                mode: .scrollable,
                historyAvailable: true,
                targetID: "pane-a"
            ),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(revision: 11, historyAvailable: false, targetID: "pane-a"),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(revision: 11, historyAvailable: true, targetID: "pane-b"),
            attachmentGeneration: 3
        )))
    }

    @Test("alternate buffer only emits cursor keys while alternate scroll is enabled")
    func alternateScrollModeGatesCursorKeys() {
        #expect(router.route(input(
            protocolState: protocolState(
                isAlternateBuffer: true,
                alternateScrollEnabled: true
            )
        )).kind == .plainAlternateKeys)
        #expect(router.route(input(
            protocolState: protocolState(
                isAlternateBuffer: true,
                alternateScrollEnabled: false
            ),
            localHistoryAvailable: false
        )).kind == .boundary)
    }

    @Test("provider copy mode scroll stays on the terminal data channel")
    func providerCopyModeUsesTerminalDataChannel() {
        let copyMode = router.route(input(
            persistent: persistent(mode: .scrollable)
        ))
        let historyEntry = router.route(input(
            persistent: persistent(historyAvailable: true)
        ))

        #expect(copyMode.transport == .terminalScrollKeys)
        #expect(historyEntry.transport == .providerControl)
    }

    private func protocolState(
        revision: UInt64 = 1,
        isAlternateBuffer: Bool = false,
        mouseTracking: TerminalMouseTracking = .off,
        alternateScrollEnabled: Bool = true,
        bracketedPasteEnabled: Bool = false,
        focusReportingEnabled: Bool = false,
        synchronizedOutputEnabled: Bool = false,
        applicationCursorEnabled: Bool = false,
        columns: Int = 80,
        rows: Int = 24
    ) -> TerminalProtocolState {
        TerminalProtocolState(
            revision: revision,
            isAlternateBuffer: isAlternateBuffer,
            mouseTracking: mouseTracking,
            alternateScrollEnabled: alternateScrollEnabled,
            bracketedPasteEnabled: bracketedPasteEnabled,
            focusReportingEnabled: focusReportingEnabled,
            synchronizedOutputEnabled: synchronizedOutputEnabled,
            applicationCursorEnabled: applicationCursorEnabled,
            columns: columns,
            rows: rows
        )
    }

    private func persistent(
        revision: UInt64 = 1,
        freshness: TerminalPersistentStateFreshness = .fresh,
        isAlternateBuffer: Bool = false,
        mode: TerminalPersistentModeCapability = .none,
        historyOwnership: PersistentTerminalHistoryOwnership = .provider,
        historyAvailable: Bool = false,
        targetID: String? = nil
    ) -> TerminalPersistentRouteState {
        TerminalPersistentRouteState(
            revision: revision,
            freshness: freshness,
            isAlternateBuffer: isAlternateBuffer,
            modeCapability: mode,
            historyOwnership: historyOwnership,
            historyAvailable: historyAvailable,
            targetID: targetID
        )
    }

    private func input(
        mode: TerminalInteractionMode = .live,
        protocolState: TerminalProtocolState? = nil,
        persistent: TerminalPersistentRouteState? = nil,
        attachmentGeneration: UInt64 = 1,
        localHistoryAvailable: Bool = true
    ) -> TerminalScrollRouteInput {
        TerminalScrollRouteInput(
            mode: mode,
            protocolState: protocolState ?? self.protocolState(),
            terminalGeneration: 2,
            attachmentGeneration: attachmentGeneration,
            persistent: persistent,
            localHistoryAvailable: localHistoryAvailable
        )
    }
}
