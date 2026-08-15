import Testing
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

    @Test("stale provider state resolves once before provider routing")
    func staleProviderStateResolves() {
        let decision = router.route(input(persistent: persistent(freshness: .stale)))

        #expect(decision.kind == .resolvePersistentState)
    }

    @Test("route token rejects protocol and attachment generation changes")
    func routeTokenValidation() throws {
        let original = input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(revision: 11),
            attachmentGeneration: 3
        )
        let token = try #require(router.route(original).token)

        #expect(token.matches(original))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 8),
            persistent: persistent(revision: 11),
            attachmentGeneration: 3
        )))
        #expect(!token.matches(input(
            protocolState: protocolState(revision: 7),
            persistent: persistent(revision: 11),
            attachmentGeneration: 4
        )))
    }

    private func protocolState(
        revision: UInt64 = 1,
        isAlternateBuffer: Bool = false,
        mouseTracking: TerminalMouseTracking = .off
    ) -> TerminalProtocolState {
        TerminalProtocolState(
            revision: revision,
            isAlternateBuffer: isAlternateBuffer,
            mouseTracking: mouseTracking,
            bracketedPasteEnabled: false,
            focusReportingEnabled: false,
            applicationCursorEnabled: false,
            columns: 80,
            rows: 24
        )
    }

    private func persistent(
        revision: UInt64 = 1,
        freshness: TerminalPersistentStateFreshness = .fresh,
        isAlternateBuffer: Bool = false,
        mode: TerminalPersistentModeCapability = .none,
        historyAvailable: Bool = false
    ) -> TerminalPersistentRouteState {
        TerminalPersistentRouteState(
            revision: revision,
            freshness: freshness,
            isAlternateBuffer: isAlternateBuffer,
            modeCapability: mode,
            historyAvailable: historyAvailable
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
