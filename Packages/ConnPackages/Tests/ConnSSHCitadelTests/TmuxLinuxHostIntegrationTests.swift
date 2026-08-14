import ConnKit
import ConnMultiplexer
@testable import ConnSSH
import Foundation
import Testing
@testable import ConnSSHCitadel

/// Real Linux SSH tmux acceptance. It is intentionally opt-in and mutating: the suite creates
/// one random Session and removes only that Session in its cleanup path.
@Suite(.enabled(
    if: linuxTmuxConfiguration != nil
        && linuxEnvironmentBool("CONN_LINUX_TMUX_ACCEPTANCE")
        && linuxEnvironmentBool("CONN_LINUX_TMUX_ALLOW_MUTATION"),
    "Set Linux SSH credentials, CONN_LINUX_TMUX_ACCEPTANCE=1 and CONN_LINUX_TMUX_ALLOW_MUTATION=1 to run"
))
struct TmuxLinuxHostIntegrationTests {
    private var configuration: LinuxTmuxConfiguration { linuxTmuxConfiguration! }

    @Test("Linux tmux provider completes lifecycle, PTY attach and live catalog")
    func providerLifecycleAndAttachment() async throws {
        try await withContext { context in
            let provider = TmuxProvider()
            let availability = try await provider.probe(in: context)
            #expect(availability.state == .available || availability.state == .degraded)

            let name = "conn-linux-accept-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
            var workspace: RemoteWorkspaceRef?
            var attachment: (any PersistentTerminalAttachment)?
            var catalog: (any PersistentTerminalCatalogAttachment)?
            do {
                let created = try await provider.createWorkspace(
                    CreateWorkspaceRequest(name: name),
                    in: context
                )
                workspace = created
                let listed = try await provider.listWorkspaces(in: context)
                #expect(listed.contains { $0.workspace.workspaceID == created.workspaceID })

                let renamed = "\(name)-renamed"
                try await provider.renameWorkspace(created, to: renamed, in: context)
                #expect(try await provider.listWorkspaces(in: context).contains {
                    $0.workspace.workspaceID == created.workspaceID && $0.name == renamed
                })

                let descriptor = try provider.makeAttachmentDescriptor(to: created, in: context)
                let openedAttachment = try await provider.openAttachment(
                    descriptor,
                    reason: .initial,
                    terminalSize: .init(cols: 80, rows: 24),
                    in: context
                )
                attachment = openedAttachment
                guard case let .byteTerminal(channel) = openedAttachment.presentation else {
                    await openedAttachment.close()
                    attachment = nil
                    throw LinuxTmuxAcceptanceError.invalidAttachment
                }
                let sentinel = "__CONN_LINUX_TMUX_E2E_ACCEPTED__"
                try await channel.write(Data("printf '\\n\(sentinel)\\n'\n".utf8))
                let output = try await linuxTmuxWithTimeout(.seconds(20)) {
                    try await linuxReadUntil(channel: channel, sentinel: sentinel)
                }
                #expect(output.contains(sentinel))
                await openedAttachment.close()
                attachment = nil

                let openedCatalog = try await provider.openCatalog(in: context)
                catalog = openedCatalog
                var iterator = openedCatalog.snapshots.makeAsyncIterator()
                let snapshot = try #require(await iterator.next())
                #expect(snapshot.freshness == .liveSubscription(observedAt: snapshot.observedAt))
                await openedCatalog.close()
                catalog = nil

                try await provider.destroyWorkspace(created, in: context)
                workspace = nil
            } catch {
                await catalog?.close()
                await attachment?.close()
                if let workspace {
                    try? await provider.destroyWorkspace(workspace, in: context)
                }
                throw error
            }
        }
    }

    private func withContext<Value: Sendable>(
        _ body: (PersistentTerminalContext) async throws -> Value
    ) async throws -> Value {
        let configuration = self.configuration
        let session = try await CitadelTransport(hostKeyStore: InMemoryHostKeyStore()).connect(
            SSHEndpoint(host: configuration.host, port: configuration.port),
            username: configuration.username,
            auth: try configuration.auth(),
            hostKeyPolicy: configuration.hostKeyPolicy
        )
        let sessionClose = LinuxTmuxSessionCloseOwner { await session.close() }
        let host = ConnKit.Host(
            id: "tmux-linux-acceptance",
            name: "tmux Linux acceptance",
            address: configuration.host,
            username: configuration.username,
            port: configuration.port,
            authKind: configuration.authKind
        )
        let platform = try await RemotePlatformDetector().detect(on: session)
        #expect(platform.kind == .linux)
        let platformContext = RemotePlatformContext(
            connectionIdentity: SSHConnectionIdentity(host: host),
            session: session,
            profile: platform
        )
        let providerJSON = try JSONEncoder().encode(TmuxProviderConfiguration())
        let profile = TerminalBackendProfile(
            id: "tmux-linux-acceptance-profile",
            hostID: host.id,
            providerID: TmuxProvider.providerID,
            providerConfigurationKey: "default",
            displayName: "tmux Linux acceptance",
            configurationJSON: String(decoding: providerJSON, as: UTF8.self)
        )
        let context = try PersistentTerminalContext(
            platformContext: platformContext,
            backendProfile: profile
        )
        let result: Result<Value, any Error>
        do {
            result = .success(try await body(context))
        } catch {
            result = .failure(error)
        }
        guard await sessionClose.close(timeout: .seconds(5)) else {
            throw LinuxTmuxAcceptanceError.cleanupTimedOut
        }
        return try result.get()
    }
}

private struct LinuxTmuxConfiguration: Sendable {
    let host: String
    let port: Int
    let username: String
    let fingerprint: String
    let password: String?
    let keyPath: String?
    let keyKind: SSHKey.Kind

    var authKind: ConnKit.Host.AuthKind { password == nil ? .key : .password }
    var hostKeyPolicy: HostKeyPolicy { .strict(expectedFingerprint: fingerprint) }

    func auth() throws -> SSHAuth {
        if let password { return .password(password) }
        guard let keyPath else { throw LinuxTmuxAcceptanceError.missingAuthentication }
        return .key(SSHPrivateKeyMaterial(
            kind: keyKind,
            pem: try String(contentsOfFile: keyPath, encoding: .utf8)
        ))
    }

    static func load(from environment: [String: String]) -> Self? {
        guard let host = linuxNonEmpty(environment, key: "CONN_LINUX_SSH_HOST"),
              let username = linuxNonEmpty(environment, key: "CONN_LINUX_SSH_USER"),
              let fingerprint = linuxNonEmpty(environment, key: "CONN_LINUX_SSH_FINGERPRINT")
        else { return nil }
        let password = linuxNonEmpty(environment, key: "CONN_LINUX_SSH_PASSWORD")
        let keyPath = linuxNonEmpty(environment, key: "CONN_LINUX_SSH_KEY_PATH")
        guard password != nil || keyPath != nil else { return nil }
        return Self(
            host: host,
            port: environment["CONN_LINUX_SSH_PORT"].flatMap(Int.init) ?? 22,
            username: username,
            fingerprint: fingerprint,
            password: password,
            keyPath: keyPath,
            keyKind: environment["CONN_LINUX_SSH_KEY_KIND"]
                .flatMap(SSHKey.Kind.init(rawValue:)) ?? .ed25519
        )
    }
}

private enum LinuxTmuxAcceptanceError: Error {
    case cleanupTimedOut
    case invalidAttachment
    case missingAuthentication
    case timeout
}

private actor LinuxTmuxSessionCloseOwner {
    private let action: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(action: @escaping @Sendable () async -> Void) { self.action = action }

    func close(timeout: Duration) async -> Bool {
        let task = self.task ?? {
            let task = Task.detached { await self.action() }
            self.task = task
            return task
        }()
        return await linuxWaitForTask(task, timeout: timeout)
    }
}

private let linuxTmuxConfiguration = LinuxTmuxConfiguration.load(
    from: ProcessInfo.processInfo.environment
)

private func linuxNonEmpty(_ environment: [String: String], key: String) -> String? {
    environment[key].flatMap { $0.isEmpty ? nil : $0 }
}

private func linuxEnvironmentBool(_ key: String) -> Bool {
    guard let value = ProcessInfo.processInfo.environment[key]?.lowercased() else { return false }
    return ["1", "true", "yes", "on"].contains(value)
}

private func linuxTmuxWithTimeout<Value: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw LinuxTmuxAcceptanceError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func linuxReadUntil(
    channel: any ShellChannel,
    sentinel: String
) async throws -> String {
    var output = Data()
    var iterator = channel.output.makeAsyncIterator()
    while let chunk = try await iterator.next() {
        output.append(chunk)
        let text = String(decoding: output, as: UTF8.self)
        if text.contains(sentinel) { return text }
    }
    return String(decoding: output, as: UTF8.self)
}

private func linuxWaitForTask(
    _ task: Task<Void, Never>,
    timeout: Duration
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await task.value
            return true
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        if !result { task.cancel() }
        return result
    }
}
