import ConnKit
import ConnMultiplexer
import ConnSSH
import Testing

@Suite("tmux operation semantics and scope")
struct TmuxOperationSemanticsTests {
    @Test("every closed operation has explicit retry and destructive semantics")
    func classifiesEveryOperation() throws {
        let session = try #require(TmuxSessionID(rawValue: "$1"))
        let window = try #require(TmuxWindowID(rawValue: "@1"))
        let pane = try #require(TmuxPaneID(rawValue: "%1"))
        let client = try TmuxClientTarget("/dev/pts/1")
        let name = try TmuxName("renamed")

        let fixtures: [(TmuxOperation, TmuxOperationSemantics)] = [
            (.createSession(name: nil), .nonIdempotentMutation),
            (.renameSession(session, to: name), .idempotentMutation),
            (.detachClient(client), .idempotentMutation),
            (.killSession(session), .destructive),
            (.selectWindow(window, for: client), .idempotentMutation),
            (.createWindow(in: session, name: nil), .nonIdempotentMutation),
            (.renameWindow(window, to: name), .idempotentMutation),
            (.killWindow(window), .destructive),
            (.selectPane(pane, for: client), .idempotentMutation),
            (.splitPane(pane, orientation: .horizontal), .nonIdempotentMutation),
            (.setPaneZoom(pane, zoomed: true), .idempotentMutation),
            (.killPane(pane), .destructive),
            (
                .scrollPaneMode(pane, direction: .up, rows: try TmuxScrollRowCount(12)),
                .nonIdempotentMutation
            ),
        ]

        #expect(fixtures.count == 13)
        for (operation, expected) in fixtures {
            #expect(operation.semantics == expected)
            #expect(operation.isDestructive == (expected == .destructive))
            #expect(operation.isMutation)
            #expect(!operation.allowsAutomaticRetryAfterPossibleDispatch)
        }
    }

    @Test("operation request binds the complete runtime scope")
    func bindsCompleteRuntimeScope() throws {
        let identity = SSHConnectionIdentity(host: Host(
            id: "host-1",
            name: "Server",
            address: "server.example",
            username: "root",
            authKind: .key,
            keyUUID: "key-1",
            jumpChain: ["jump-1"]
        ))
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )
        let scope = try TmuxOperationScope(
            connectionIdentity: identity,
            profileID: "profile-1",
            instanceToken: token,
            generation: 7
        )
        let operation = TmuxOperation.createSession(name: nil)
        let request = TmuxOperationRequest(scope: scope, operation: operation)

        #expect(request.scope.connectionIdentity == identity)
        #expect(request.scope.profileID == "profile-1")
        #expect(request.scope.instanceToken == token)
        #expect(request.scope.generation == 7)
        #expect(request.operation == operation)
    }

    @Test("profile scope rejects empty, controlled and oversized identifiers")
    func rejectsInvalidProfileScope() throws {
        let identity = SSHConnectionIdentity(host: Host(
            id: "host-1",
            name: "Server",
            address: "server.example",
            username: "root"
        ))
        let token = try TmuxServerInstanceToken(
            resolvedSocketPath: "/tmp/tmux/default",
            serverPID: 100,
            serverStartTime: 200
        )

        for profileID in ["", "profile\n2", String(repeating: "p", count: 257)] {
            #expect(throws: TmuxOperationError.invalidProfileID) {
                try TmuxOperationScope(
                    connectionIdentity: identity,
                    profileID: profileID,
                    instanceToken: token,
                    generation: 1
                )
            }
        }
    }
}
