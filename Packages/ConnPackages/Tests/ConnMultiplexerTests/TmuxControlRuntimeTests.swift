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

    @Test("size policy participates only when the verified data client is alone")
    func arbitratesDataClientSizeParticipation() throws {
        let session = try #require(TmuxSessionID(rawValue: "$1"))
        let dataID = TmuxClientID(targetName: "/dev/pts/1", processID: 1, createdAt: 1)
        let externalID = TmuxClientID(targetName: "/dev/pts/2", processID: 2, createdAt: 2)
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

        #expect(TmuxDataClientSizePolicy.decision(
            for: identity,
            clients: [dataID: client(
                id: dataID,
                flags: [.ignoreSize],
                role: .connInteractive(attachmentID: "attachment-1"),
                participation: .ignored
            )],
            supportsIgnoreSize: true
        ) == .disableIgnoreSize)

        #expect(TmuxDataClientSizePolicy.decision(
            for: identity,
            clients: [
                dataID: client(
                    id: dataID,
                    flags: [],
                    role: .connInteractive(attachmentID: "attachment-1"),
                    participation: .participating
                ),
                externalID: client(
                    id: externalID,
                    flags: nil,
                    role: .external,
                    participation: .unknown
                ),
            ],
            supportsIgnoreSize: true
        ) == .enableIgnoreSize)

        #expect(TmuxDataClientSizePolicy.decision(
            for: identity,
            clients: [dataID: client(
                id: dataID,
                flags: [.ignoreSize],
                role: .connInteractive(attachmentID: "attachment-1"),
                participation: .ignored
            )],
            supportsIgnoreSize: false
        ) == .unchanged)

        let secondDataID = TmuxClientID(
            targetName: "/dev/pts/3",
            processID: 3,
            createdAt: 3
        )
        let secondIdentity = TmuxControlInteractiveIdentity(
            attachmentID: "attachment-2",
            clientID: secondDataID,
            requestedSessionID: session
        )
        let twoIgnoredConnClients = [
            dataID: client(
                id: dataID,
                flags: [.ignoreSize],
                role: .connInteractive(attachmentID: "attachment-1"),
                participation: .ignored
            ),
            secondDataID: client(
                id: secondDataID,
                flags: [.ignoreSize],
                role: .connInteractive(attachmentID: "attachment-2"),
                participation: .ignored
            ),
        ]
        #expect(TmuxDataClientSizePolicy.decision(
            for: identity,
            clients: twoIgnoredConnClients,
            supportsIgnoreSize: true
        ) == .disableIgnoreSize)
        #expect(TmuxDataClientSizePolicy.decision(
            for: secondIdentity,
            clients: twoIgnoredConnClients,
            supportsIgnoreSize: true
        ) == .unchanged)
        let convergedConnClients = [
            dataID: client(
                id: dataID,
                flags: [],
                role: .connInteractive(attachmentID: "attachment-1"),
                participation: .participating
            ),
            secondDataID: client(
                id: secondDataID,
                flags: [.ignoreSize],
                role: .connInteractive(attachmentID: "attachment-2"),
                participation: .ignored
            ),
        ]
        #expect(TmuxDataClientSizePolicy.decision(
            for: identity,
            clients: convergedConnClients,
            supportsIgnoreSize: true
        ) == .unchanged)
        #expect(TmuxDataClientSizePolicy.decision(
            for: secondIdentity,
            clients: convergedConnClients,
            supportsIgnoreSize: true
        ) == .unchanged)

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
        profileID: "profile-1",
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
