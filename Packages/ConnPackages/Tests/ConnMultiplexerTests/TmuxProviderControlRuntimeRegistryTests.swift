@testable import ConnMultiplexer
import ConnKit
import ConnSSH
import Foundation
import Testing

@Suite("tmux provider control runtime registry")
struct TmuxProviderControlRuntimeRegistryTests {
    @Test("identity survives control eviction and is restored for the next observation")
    func evictsControlRuntimeWithoutLosingAttachmentIdentity() async throws {
        let fixture = try RegistryFixture()
        let registry = TmuxProviderControlRuntimeRegistry()
        let firstChannel = RegistryTrackingProcessChannel()
        let firstRuntime = try fixture.runtime(channel: firstChannel)
        let firstPreflight = try #require(await registry.acquireRuntime(for: fixture.scope) {
            firstRuntime
        })
        let firstAdapter = RegistryHubAdapter(fixture: fixture)
        let attachmentLease = try #require(await registry.acquireAttachment(
            firstPreflight,
            attachmentID: fixture.attachmentID,
            requestedSessionID: fixture.session,
            makeHub: { _ in
                let hub = try? TmuxControlHub(
                    scope: fixture.scope,
                    initialSnapshot: fixture.externalSnapshot,
                    adapter: firstAdapter
                )
                return hub.map { TmuxProviderControlSetup(hub: $0, identity: fixture.identity) }
            },
            resolveIdentity: { _ in fixture.identity }
        ))

        #expect(firstChannel.closeCount == 1)

        let secondChannel = RegistryTrackingProcessChannel()
        let secondRuntime = try fixture.runtime(channel: secondChannel)
        let secondPreflight = try #require(await registry.acquireRuntime(for: fixture.scope) {
            secondRuntime
        })
        let secondAdapter = RegistryHubAdapter(fixture: fixture)
        let catalogLease = try #require(await registry.acquireCatalog(secondPreflight) { _ in
            try? TmuxControlHub(
                scope: fixture.scope,
                initialSnapshot: fixture.externalSnapshot,
                adapter: secondAdapter
            )
        })
        var iterator = catalogLease.observation.snapshots.makeAsyncIterator()
        let restored = try #require(await iterator.next())
        guard case let .connInteractive(attachmentID) = restored.clients[fixture.dataClient]?.role
        else {
            Issue.record("reopened observation did not restore the data attachment identity")
            return
        }
        #expect(attachmentID == fixture.attachmentID)

        await registry.releaseCatalog(catalogLease)
        #expect(secondChannel.closeCount == 1)
        await registry.release(attachmentLease)
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
            profileID: "profile-1",
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
        return try TmuxServerSnapshot(
            instance: .init(token: token, version: "tmux 3.5a"),
            sessions: [session: .init(
                id: session,
                name: "main",
                groupName: nil,
                currentWindowID: window
            )],
            sessionGroups: [:],
            windows: [window: .init(
                id: window,
                name: "window",
                layout: nil,
                isZoomed: false,
                activePaneID: pane
            )],
            panes: [pane: .init(
                id: pane,
                windowID: window,
                index: 0,
                title: .unavailable,
                currentCommand: .unavailable,
                currentPath: .unavailable,
                size: .init(cols: 80, rows: 24),
                isDead: false
            )],
            windowLinks: [.init(sessionID: session, windowID: window, index: 0)],
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

    init(fixture: RegistryFixture) {
        self.fixture = fixture
    }

    func execute(
        _ request: TmuxOperationRequest,
        timeout: Duration,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxControlHubOperationReceipt {
        TmuxControlHubOperationReceipt(request: request, output: [])
    }

    func loadSnapshot(
        scope: TmuxOperationScope,
        reason: TmuxControlHubSnapshotReason,
        identities: Set<TmuxControlInteractiveIdentity>
    ) async throws -> TmuxServerSnapshot {
        try fixture.snapshot(identities: identities)
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
