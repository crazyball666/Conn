@testable import ConnMultiplexer
import ConnKit
import ConnSSH
import Foundation
import Testing

@Suite("tmux control runtime")
struct TmuxControlRuntimeTests {
    @Test("协商结果区分支持能力与当前 client 实际启用配置")
    func enablesSafeFlagsAndMetadataSubscriptions() async throws {
        let channel = NegotiatingControlProcessChannel { command in
            !command.contains("active-pane") && !command.contains("pause-after")
        }
        let runtime = try TmuxControlRuntime(
            channel: channel,
            scope: try makeRuntimeScope(),
            dialect: .init(commandGuardShape: .threeFields, snapshotCodec: .quoted),
            processIdentity: .init(tty: "/dev/pts/9", processID: 900)
        )
        channel.startProtocol()

        try await runtime.start(timeout: .seconds(2))

        #expect(await runtime.capabilities == TmuxNegotiatedCapabilities(
            supportedClientFlags: [.noOutput, .waitExit, .ignoreSize],
            supportsFormatSubscriptions: true
        ))
        #expect(await runtime.configuration == TmuxControlClientConfiguration(
            enabledClientFlags: [.noOutput, .waitExit, .ignoreSize],
            activeSubscriptionNames: [
                "__conn_session_attached__",
                "__conn_pane_title__",
                "__conn_pane_current_command__",
                "__conn_pane_current_path__",
            ]
        ))

        let commands = channel.commands
        #expect(commands.contains("refresh-client -f no-output"))
        #expect(commands.contains("refresh-client -f wait-exit"))
        #expect(commands.contains("refresh-client -f ignore-size"))
        #expect(!commands.contains("refresh-client -f active-pane"))
        #expect(commands.contains("refresh-client -B __conn_session_attached__::#{session_attached}"))
        #expect(commands.contains("refresh-client -B __conn_pane_title__:%*:#{pane_title}"))
        #expect(commands.contains("refresh-client -B __conn_pane_current_command__:%*:#{pane_current_command}"))
        #expect(commands.contains("refresh-client -B __conn_pane_current_path__:%*:#{pane_current_path}"))
        await runtime.close()
    }

    @Test("视口可见性只更新绑定 data client 并在显示时完整重绘")
    func updatesExactDataClientViewport() async throws {
        let channel = NegotiatingControlProcessChannel { _ in true }
        let runtime = try TmuxControlRuntime(
            channel: channel,
            scope: try makeRuntimeScope(),
            dialect: .init(commandGuardShape: .threeFields, snapshotCodec: .quoted),
            processIdentity: .init(tty: "/dev/pts/9", processID: 900)
        )
        channel.startProtocol()
        try await runtime.start(timeout: .seconds(2))
        let identity = TmuxControlInteractiveIdentity(
            attachmentID: "attachment-1",
            clientID: TmuxClientID(targetName: "/dev/pts/1", processID: 1, createdAt: 1),
            requestedSessionID: try #require(TmuxSessionID(rawValue: "$1"))
        )

        try await runtime.updateDataClientViewport(identity, isVisible: false)
        try await runtime.updateDataClientViewport(identity, isVisible: true)

        let commands = channel.commands
        #expect(commands.contains("refresh-client -t '/dev/pts/1' -f 'ignore-size'"))
        let participateIndex = try #require(
            commands.firstIndex(of: "refresh-client -t '/dev/pts/1' -f '!ignore-size'")
        )
        let redrawIndex = try #require(
            commands.firstIndex(of: "refresh-client -t '/dev/pts/1'")
        )
        #expect(participateIndex < redrawIndex)
        #expect(!commands.contains("refresh-client -t '/dev/pts/2' -f 'ignore-size'"))
        await runtime.close()
    }

    @Test("active Pane flag remains scoped to the verified data client")
    func enablesActivePaneForVerifiedDataClient() throws {
        let session = try #require(TmuxSessionID(rawValue: "$1"))
        let dataID = TmuxClientID(targetName: "/dev/pts/1", processID: 1, createdAt: 1)
        let identity = TmuxControlInteractiveIdentity(
            attachmentID: "attachment-1",
            clientID: dataID,
            requestedSessionID: session
        )
        let now = Date(timeIntervalSince1970: 100)

        func client(
            id: TmuxClientID,
            flags: Set<TmuxClientFlag>?,
            role: TmuxClientRole,
            participation: TmuxClientSizeParticipation
        ) -> TmuxClientSnapshot {
            TmuxClientSnapshot(
                id: id,
                sessionID: session,
                currentWindowID: nil,
                activePaneID: nil,
                flags: flags,
                role: role,
                kind: .interactiveTerminal,
                sizeParticipation: participation,
                observedAt: now
            )
        }

        #expect(TmuxDataClientFocusPolicy.shouldEnableActivePane(
            for: identity,
            clients: [dataID: client(
                id: dataID,
                flags: [],
                role: .connInteractive(attachmentID: "attachment-1"),
                participation: .participating
            )],
            supportsActivePane: true
        ))
        #expect(!TmuxDataClientFocusPolicy.shouldEnableActivePane(
            for: identity,
            clients: [dataID: client(
                id: dataID,
                flags: [.activePane],
                role: .connInteractive(attachmentID: "attachment-1"),
                participation: .participating
            )],
            supportsActivePane: true
        ))
    }
}

private func makeRuntimeScope() throws -> TmuxOperationScope {
    try TmuxOperationScope(
        connectionIdentity: SSHConnectionIdentity(host: Host(
            id: "host-1",
            name: "Server",
            address: "server.example",
            username: "root"
        )),
        configurationKey: "profile-1",
        instanceToken: TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux-1000/default",
            serverPID: 1234,
            serverStartTime: 5678
        ),
        generation: 7
    )
}

private final class NegotiatingControlProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>
    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let accepts: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var recordedCommands: [String] = []
    private var commandNumber: UInt64 = 0

    init(accepts: @escaping @Sendable (String) -> Bool) {
        self.accepts = accepts
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    var commands: [String] {
        lock.withLock { recordedCommands }
    }

    func startProtocol() {
        continuation.yield(.stdout(TmuxProtocolMarker.start))
        continuation.yield(.stdout(Data("%begin 9 0 0\n%end 9 0 0\n".utf8)))
    }

    func write(_ data: Data) async throws {
        let command = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard !command.isEmpty else {
            continuation.finish()
            return
        }
        let response: String = lock.withLock {
            recordedCommands.append(command)
            commandNumber &+= 1
            let marker = accepts(command) ? "%end" : "%error"
            return "%begin 10 \(commandNumber) 0\n\(marker) 10 \(commandNumber) 0\n"
        }
        continuation.yield(.stdout(Data(response.utf8)))
    }

    func resize(_ size: TermSize) async throws {}

    func result() async throws -> RemoteProcessExit {
        .init(exitCode: 0, signal: nil)
    }

    func close() async {
        continuation.finish()
    }
}
