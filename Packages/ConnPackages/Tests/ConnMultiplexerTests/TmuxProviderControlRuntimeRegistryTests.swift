@testable import ConnMultiplexer
import ConnKit
import ConnSSH
import Foundation
import Testing

@Suite("tmux provider control runtime registry")
struct TmuxProviderControlRuntimeRegistryTests {
    @Test("new Hub registers against its validated initial snapshot without a redundant refresh")
    func newHubRegistrationDoesNotReloadValidatedSnapshot() async throws {
        let fixture = try RegistryFixture()
        let registry = TmuxProviderControlRuntimeRegistry()
        let channel = RegistryTrackingProcessChannel()
        let runtime = try fixture.runtime(channel: channel)
        let preflight = try #require(await registry.acquireRuntime(for: fixture.scope) {
            runtime
        })
        let adapter = RegistryHubAdapter(fixture: fixture)
        let validatedSnapshot = try fixture.snapshot(identities: [fixture.identity])

        let attachment = try #require(await registry.acquireAttachment(
            preflight,
            attachmentID: fixture.attachmentID,
            attachmentGeneration: 3,
            requestedSessionID: fixture.session,
            makeHub: { _ in
                let hub = try? TmuxControlHub(
                    scope: fixture.scope,
                    initialSnapshot: validatedSnapshot,
                    adapter: adapter
                )
                return hub.map { TmuxProviderControlSetup(hub: $0, identity: fixture.identity) }
            },
            resolveIdentity: { _ in fixture.identity }
        ))

        #expect(await adapter.snapshotLoadCount == 0)
        _ = try await registry.resolveInteraction(attachment)
        await registry.release(attachment)
        #expect(channel.closeCount == 1)
    }

    @Test("interactive attachment keeps control alive and dispatches only against its verified pane")
    func interactiveAttachmentOwnsObservationAndModeScroll() async throws {
        let fixture = try RegistryFixture()
        let registry = TmuxProviderControlRuntimeRegistry()
        let firstChannel = RegistryTrackingProcessChannel()
        let firstRuntime = try fixture.runtime(channel: firstChannel)
        let firstPreflight = try #require(await registry.acquireRuntime(for: fixture.scope) {
            firstRuntime
        })
        let firstAdapter = RegistryHubAdapter(fixture: fixture)
        let validatedInitialSnapshot = try fixture.snapshot(identities: [fixture.identity])
        let attachmentLease = try #require(await registry.acquireAttachment(
            firstPreflight,
            attachmentID: fixture.attachmentID,
            attachmentGeneration: 3,
            requestedSessionID: fixture.session,
            makeHub: { _ in
                let hub = try? TmuxControlHub(
                    scope: fixture.scope,
                    initialSnapshot: validatedInitialSnapshot,
                    adapter: firstAdapter
                )
                return hub.map { TmuxProviderControlSetup(hub: $0, identity: fixture.identity) }
            },
            resolveIdentity: { _ in fixture.identity }
        ))

        #expect(firstChannel.closeCount == 0)

        var snapshots = attachmentLease.snapshots.makeAsyncIterator()
        let firstSnapshot = try #require(await snapshots.next())
        #expect(firstSnapshot.clients[fixture.dataClient]?.role == .connInteractive(
            attachmentID: fixture.attachmentID
        ))

        let state = try await registry.resolveInteraction(attachmentLease)
        let target = state.target
        #expect(state.modeCapability == .scrollable)
        #expect(state.revision == validatedInitialSnapshot.revision)

        try await registry.updateViewport(attachmentLease, isVisible: true)
        #expect(await firstAdapter.viewportVisibilities == [true])
        #expect(await firstAdapter.viewportIdentities == [fixture.identity])

        let request = try PersistentTerminalModeScrollRequest(
            target: target,
            attachmentGeneration: 3,
            direction: .up,
            rows: 7
        )
        try await registry.scrollInteraction(attachmentLease, request: request)
        #expect(await firstAdapter.operations == [
            .scrollPaneMode(
                fixture.pane,
                direction: .up,
                rows: try TmuxScrollRowCount(7)
            ),
        ])

        _ = try await registry.performQuickAction(
            attachmentLease,
            request: .init(
                actionID: TmuxTerminalQuickAction.sessionList.rawValue,
                target: target,
                attachmentGeneration: 3,
                expectedStateRevision: state.revision
            )
        )
        _ = try await registry.performQuickAction(
            attachmentLease,
            request: .init(
                actionID: TmuxTerminalQuickAction.windowList.rawValue,
                target: target,
                attachmentGeneration: 3,
                expectedStateRevision: state.revision
            )
        )

        _ = try await registry.performQuickAction(
            attachmentLease,
            request: .init(
                actionID: TmuxTerminalQuickAction.splitHorizontal.rawValue,
                target: target,
                attachmentGeneration: 3,
                expectedStateRevision: state.revision
            )
        )
        _ = try await registry.performQuickAction(
            attachmentLease,
            request: .init(
                actionID: TmuxTerminalQuickAction.tiledLayout.rawValue,
                target: target,
                attachmentGeneration: 3,
                expectedStateRevision: state.revision
            )
        )
        _ = try await registry.performQuickAction(
            attachmentLease,
            request: .init(
                actionID: TmuxTerminalQuickAction.newWindow.rawValue,
                target: target,
                attachmentGeneration: 3,
                expectedStateRevision: state.revision
            )
        )
        await #expect(throws: PersistentTerminalInteractionError.invalidQuickActionRepeatCount(0)) {
            try await registry.performQuickAction(
                attachmentLease,
                request: .init(
                    actionID: TmuxTerminalQuickAction.nextWindow.rawValue,
                    target: target,
                    attachmentGeneration: 3,
                    expectedStateRevision: state.revision,
                    repeatCount: 0
                )
            )
        }
        await #expect(throws: PersistentTerminalInteractionError.invalidQuickActionRepeatCount(2)) {
            try await registry.performQuickAction(
                attachmentLease,
                request: .init(
                    actionID: TmuxTerminalQuickAction.splitHorizontal.rawValue,
                    target: target,
                    attachmentGeneration: 3,
                    expectedStateRevision: state.revision,
                    repeatCount: 2
                )
            )
        }
        _ = try await registry.performQuickAction(
            attachmentLease,
            request: .init(
                actionID: TmuxTerminalQuickAction.nextWindow.rawValue,
                target: target,
                attachmentGeneration: 3,
                expectedStateRevision: state.revision,
                repeatCount: 4
            )
        )
        let clientTarget = try TmuxClientTarget(fixture.dataClient.targetName)
        let createdPane = try #require(TmuxPaneID(rawValue: "%2"))
        let createdWindow = try #require(TmuxWindowID(rawValue: "@2"))
        #expect(await firstAdapter.operations == [
            .scrollPaneMode(
                fixture.pane,
                direction: .up,
                rows: try TmuxScrollRowCount(7)
            ),
            .chooseTree(fixture.pane, scope: .sessions),
            .chooseTree(fixture.pane, scope: .windows),
            .splitPane(fixture.pane, orientation: .horizontal),
            .selectPane(createdPane, for: clientTarget),
            .applyPaneLayout(fixture.window, layout: .tiled),
            .createWindow(in: fixture.session, name: nil),
            .selectWindow(createdWindow, for: clientTarget),
            .selectRelativeWindow(
                in: fixture.session,
                direction: .next,
                steps: try TmuxWindowNavigationStepCount(4),
                for: clientTarget
            ),
        ])

        let staleGeneration = try PersistentTerminalModeScrollRequest(
            target: target,
            attachmentGeneration: 2,
            direction: .up,
            rows: 1
        )
        await #expect(throws: PersistentTerminalInteractionError.staleAttachmentGeneration) {
            try await registry.scrollInteraction(attachmentLease, request: staleGeneration)
        }
        let wrongPane = try PersistentTerminalModeScrollRequest(
            target: .init(
                providerID: TmuxProvider.providerID,
                workspaceID: fixture.session.rawValue,
                targetID: "%999"
            ),
            attachmentGeneration: 3,
            direction: .up,
            rows: 1
        )
        await #expect(throws: TmuxInteractionError.targetMismatch) {
            try await registry.scrollInteraction(attachmentLease, request: wrongPane)
        }
        #expect(await firstAdapter.operations.count == 9)

        await registry.release(attachmentLease)
        #expect(firstChannel.closeCount == 1)
    }

    @Test("交互 Facet 将已绑定操作交给 Hub 排队而不按瞬时 readiness 拒绝")
    func interactionFacetDelegatesBoundOperationsToHub() async throws {
        let fixture = try RegistryFixture()
        let registry = TmuxProviderControlRuntimeRegistry()
        let channel = RegistryTrackingProcessChannel()
        let runtime = try fixture.runtime(channel: channel)
        let preflight = try #require(await registry.acquireRuntime(for: fixture.scope) {
            runtime
        })
        let adapter = RegistryHubAdapter(fixture: fixture)
        let snapshot = try fixture.snapshot(identities: [fixture.identity])
        let dataClientProcessID = try #require(fixture.dataClient.processID)
        let attachment = try #require(await registry.acquireAttachment(
            preflight,
            attachmentID: fixture.attachmentID,
            attachmentGeneration: 3,
            requestedSessionID: fixture.session,
            makeHub: { _ in
                let hub = try? TmuxControlHub(
                    scope: fixture.scope,
                    initialSnapshot: snapshot,
                    adapter: adapter
                )
                return hub.map { TmuxProviderControlSetup(hub: $0, identity: fixture.identity) }
            },
            resolveIdentity: { _ in fixture.identity }
        ))
        let facet = TmuxInteractionFacet(
            attachmentGeneration: 3,
            historyBackend: TmuxOneShotInteractionBackend(
                executor: RegistryUnusedReadExecutor(),
                captureExecutor: RegistryUnusedCaptureExecutor(),
                scope: fixture.scope,
                dialect: .init(commandGuardShape: .threeFields, snapshotCodec: .quoted),
                attachmentID: fixture.attachmentID,
                attachmentGeneration: 3,
                tty: fixture.dataClient.targetName,
                processID: dataClientProcessID,
                nonceFactory: { try TmuxInvocationNonce("unused") }
            )
        )
        await facet.install(attachment)

        let outcome = try await facet.performQuickAction(PersistentTerminalQuickActionRequest(
            actionID: TmuxTerminalQuickAction.nextWindow.rawValue,
            target: PersistentTerminalInteractionTarget(
                providerID: TmuxProvider.providerID,
                workspaceID: fixture.session.rawValue,
                targetID: fixture.pane.rawValue
            ),
            attachmentGeneration: 3,
            expectedStateRevision: snapshot.revision
        ))

        #expect(outcome == .performed)
        #expect(await adapter.operations == [
            .selectRelativeWindow(
                in: fixture.session,
                direction: .next,
                steps: try TmuxWindowNavigationStepCount(1),
                for: try TmuxClientTarget(fixture.dataClient.targetName)
            ),
        ])
        await facet.close()
        #expect(channel.closeCount == 1)
    }
}

private enum RegistryUnusedBackendError: Error {
    case unexpectedlyCalled
}

private struct RegistryUnusedReadExecutor: TmuxReadOnlyCommandExecuting {
    func execute(
        _ request: TmuxControlRequest,
        scope: TmuxOperationScope,
        timeout: Duration
    ) async throws -> TmuxReadOnlyCommandExecution {
        throw RegistryUnusedBackendError.unexpectedlyCalled
    }
}

private struct RegistryUnusedCaptureExecutor: TmuxPaneHistoryCaptureExecuting {
    func capture(
        paneID: TmuxPaneID,
        startLine: Int,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> TmuxPaneCaptureResult {
        throw RegistryUnusedBackendError.unexpectedlyCalled
    }
}

private struct RegistryFixture: Sendable {
    let scope: TmuxOperationScope
    let session: TmuxSessionID
    let window: TmuxWindowID
    let pane: TmuxPaneID
    let dataClient: TmuxClientID
    let attachmentID = "attachment-1"
    let externalSnapshot: TmuxServerSnapshot

    init() throws {
        session = try #require(TmuxSessionID(rawValue: "$1"))
        window = try #require(TmuxWindowID(rawValue: "@1"))
        pane = try #require(TmuxPaneID(rawValue: "%1"))
        dataClient = TmuxClientID(
            targetName: "/dev/pts/1",
            processID: 101,
            createdAt: 1_000
        )
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
        scope = try TmuxOperationScope(
            connectionIdentity: SSHConnectionIdentity(host: Host(
                id: "host-1",
                name: "Server",
                address: "server.example",
                username: "root"
            )),
            configurationKey: "profile-1",
            instanceToken: token,
            generation: 7
        )
        externalSnapshot = try Self.snapshot(
            token: token,
            session: session,
            window: window,
            pane: pane,
            dataClient: dataClient,
            role: .external
        )
    }

    var identity: TmuxControlInteractiveIdentity {
        TmuxControlInteractiveIdentity(
            attachmentID: attachmentID,
            clientID: dataClient,
            requestedSessionID: session
        )
    }

    func runtime(channel: any RemoteProcessChannel) throws -> TmuxControlRuntime {
        try TmuxControlRuntime(
            channel: channel,
            scope: scope,
            dialect: .init(commandGuardShape: .threeFields, snapshotCodec: .quoted),
            processIdentity: .init(tty: "/dev/pts/9", processID: 900)
        )
    }

    func snapshot(identities: Set<TmuxControlInteractiveIdentity>) throws -> TmuxServerSnapshot {
        let role: TmuxClientRole = identities.contains(identity)
            ? .connInteractive(attachmentID: attachmentID)
            : .external
        return try Self.snapshot(
            token: scope.instanceToken,
            session: session,
            window: window,
            pane: pane,
            dataClient: dataClient,
            role: role
        )
    }

    private static func snapshot(
        token: TmuxServerInstanceToken,
        session: TmuxSessionID,
        window: TmuxWindowID,
        pane: TmuxPaneID,
        dataClient: TmuxClientID,
        role: TmuxClientRole
    ) throws -> TmuxServerSnapshot {
        let observedAt = Date(timeIntervalSince1970: 100)
        let alternateWindow = try #require(TmuxWindowID(rawValue: "@9"))
        return try TmuxServerSnapshot(
            instance: .init(token: token, version: "tmux 3.5a"),
            sessions: [session: .init(
                id: session,
                name: "main",
                groupName: nil,
                currentWindowID: window
            )],
            sessionGroups: [:],
            windows: [
                window: .init(
                    id: window,
                    name: "window",
                    layout: nil,
                    isZoomed: false,
                    activePaneID: pane
                ),
                alternateWindow: .init(
                    id: alternateWindow,
                    name: "alternate",
                    layout: nil,
                    isZoomed: false,
                    activePaneID: nil
                ),
            ],
            panes: [pane: .init(
                id: pane,
                windowID: window,
                index: 0,
                title: .unavailable,
                currentCommand: .unavailable,
                currentPath: .unavailable,
                interaction: .init(
                    alternateOn: .init(
                        value: false,
                        freshness: .snapshot(observedAt: observedAt)
                    ),
                    paneInMode: .init(
                        value: true,
                        freshness: .snapshot(observedAt: observedAt)
                    ),
                    mode: .init(
                        value: "copy-mode",
                        freshness: .snapshot(observedAt: observedAt)
                    ),
                    mouseAnyFlag: .init(
                        value: false,
                        freshness: .snapshot(observedAt: observedAt)
                    ),
                    historySize: .init(
                        value: 100,
                        freshness: .snapshot(observedAt: observedAt)
                    ),
                    historyLimit: .init(
                        value: 2_000,
                        freshness: .snapshot(observedAt: observedAt)
                    )
                ),
                size: .init(cols: 80, rows: 24),
                isDead: false
            )],
            windowLinks: [
                .init(sessionID: session, windowID: window, index: 0),
                .init(sessionID: session, windowID: alternateWindow, index: 1),
            ],
            clients: [dataClient: .init(
                id: dataClient,
                sessionID: session,
                currentWindowID: window,
                activePaneID: pane,
                flags: [.ignoreSize, .activePane],
                role: role,
                kind: .interactiveTerminal,
                sizeParticipation: .ignored,
                observedAt: observedAt
            )],
            observedAt: observedAt,
            revision: 0,
            impactRevision: 0
        )
    }
}

private actor RegistryHubAdapter: TmuxControlHubAdapter {
    let fixture: RegistryFixture
    private(set) var operations: [TmuxOperation] = []
    private(set) var snapshotLoadCount = 0
    private(set) var viewportIdentities: [TmuxControlInteractiveIdentity] = []
    private(set) var viewportVisibilities: [Bool] = []

    init(fixture: RegistryFixture) {
        self.fixture = fixture
    }

    func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxControlHubOperationReceipt {
        operations.append(request.operation)
        let output: [Data]
        switch request.operation {
        case .createWindow:
            output = [Data("@2\n".utf8)]
        case .splitPane:
            output = [Data("%2\n".utf8)]
        default:
            output = []
        }
        return TmuxControlHubOperationReceipt(request: request, output: output)
    }

    func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot {
        snapshotLoadCount += 1
        return try fixture.snapshot(identities: identities)
    }

    func updateDataClientViewport(
        scope: TmuxOperationScope,
        identity: TmuxControlInteractiveIdentity,
        isVisible: Bool
    ) async throws {
        _ = scope
        viewportIdentities.append(identity)
        viewportVisibilities.append(isVisible)
    }

    func demandChanged(_ demand: TmuxControlHubDemand) async {}
}

private final class RegistryTrackingProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>
    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let lock = NSLock()
    private var closes = 0

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    var closeCount: Int { lock.withLock { closes } }

    func write(_ data: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func result() async throws -> RemoteProcessExit { .init(exitCode: 0, signal: nil) }

    func close() async {
        lock.withLock { closes += 1 }
        continuation.finish()
    }
}
