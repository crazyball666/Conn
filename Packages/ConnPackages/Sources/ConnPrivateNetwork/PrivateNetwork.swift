import ConnCrypto
import ConnKit
import ConnSSH
import Foundation
import Network

/// Embedded private-network runtime status. It describes this host connection only;
/// Conn never installs a system VPN profile or changes the device routing table.
public enum PrivateNetworkStatus: Sendable, Equatable {
    case stopped
    case starting
    case running
    case failed(String)
}

public struct PrivateNetworkProxyEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public protocol PrivateNetworkProxyLease: AnyObject, Sendable {
    var endpoint: PrivateNetworkProxyEndpoint { get }
    func close() async
}

public protocol PrivateNetworkClient: AnyObject, Sendable {
    var status: PrivateNetworkStatus { get }
    func start() async throws
    func openTCPProxy(to endpoint: SSHEndpoint) async throws -> any PrivateNetworkProxyLease
    func close() async
}

public protocol PrivateNetworkClientFactory: Sendable {
    func makeClient(
        for profile: PrivateNetworkProfile,
        authKey: String?
    ) async throws -> any PrivateNetworkClient
}

public enum PrivateNetworkError: Error, Sendable, Equatable {
    case profileNotFound(String)
    case missingAuthKey(String)
    case unsupportedOnThisBuild
    case invalidControlURL(String)
    case proxyUnavailable
    case proxyHandshakeFailed
    case proxyAuthenticationFailed
}

/// One process-wide registry, injected into SSH transport. A profile is started lazily
/// and reference counted by proxy leases, so another host does not inherit its route.
public actor PrivateNetworkRegistry {
    private struct Runtime {
        let client: any PrivateNetworkClient
        var leaseCount: Int
    }

    private struct Closing {
        let id = UUID()
        let task: Task<Void, Never>
    }

    private let profileRepository: any PrivateNetworkProfileRepository
    private let credentialStore: any CredentialStore
    private let factory: any PrivateNetworkClientFactory
    private let idleTimeout: Duration
    private var runtimes: [String: Runtime] = [:]
    private var startingClients: [String: Task<any PrivateNetworkClient, Error>] = [:]
    private var closingClients: [String: Closing] = [:]
    private var idleTasks: [String: Task<Void, Never>] = [:]

    public init(
        profileRepository: any PrivateNetworkProfileRepository,
        credentialStore: any CredentialStore,
        factory: (any PrivateNetworkClientFactory)? = nil,
        idleTimeout: Duration = .seconds(45)
    ) {
        self.profileRepository = profileRepository
        self.credentialStore = credentialStore
        self.factory = factory ?? DefaultPrivateNetworkClientFactory(credentialStore: credentialStore)
        self.idleTimeout = idleTimeout
    }

    public func openProxy(
        profileID: String,
        to endpoint: SSHEndpoint
    ) async throws -> any PrivateNetworkProxyLease {
        idleTasks.removeValue(forKey: profileID)?.cancel()
        let client = try await client(for: profileID)
        let clientID = ObjectIdentifier(client)
        guard let runtime = runtimes[profileID], ObjectIdentifier(runtime.client) == clientID else {
            throw PrivateNetworkError.proxyUnavailable
        }

        // Retain before the async proxy setup. Actor reentrancy can let another
        // host request the same profile while this await is in progress; counting
        // first prevents either request from overwriting the other's lease.
        runtimes[profileID] = Runtime(client: runtime.client, leaseCount: runtime.leaseCount + 1)

        let rawLease: any PrivateNetworkProxyLease
        do {
            rawLease = try await client.openTCPProxy(to: endpoint)
        } catch {
            await release(profileID: profileID, clientID: clientID, evictOnFailure: true)
            throw error
        }
        return RegistryLease(rawLease: rawLease) { [weak self] in
            await self?.release(profileID: profileID, clientID: clientID)
        }
    }

    /// Releases idle, unreferenced runtimes after prolonged background suspension.
    /// Healthy active leases are preserved to avoid disrupting ongoing foreground sessions.
    public func resumeAfterBackground(idleFor: TimeInterval) async {
        guard idleFor > 30 else { return }
        let idleProfileIDs = runtimes.compactMap { profileID, runtime in
            runtime.leaseCount == 0 ? profileID : nil
        }
        for profileID in idleProfileIDs {
            await stop(profileID: profileID)
        }
    }

    public func status(profileID: String) -> PrivateNetworkStatus {
        runtimes[profileID]?.client.status ?? .stopped
    }

    public func stop(profileID: String) async {
        idleTasks.removeValue(forKey: profileID)?.cancel()
        if let runtime = runtimes.removeValue(forKey: profileID) {
            closingClients[profileID] = Closing(task: Task { await runtime.client.close() })
        }
        await waitForClose(profileID: profileID)
    }

    public func stopAll() async {
        for task in idleTasks.values { task.cancel() }
        idleTasks.removeAll()
        let current = runtimes
        runtimes.removeAll()
        for (profileID, runtime) in current {
            closingClients[profileID] = Closing(task: Task { await runtime.client.close() })
        }
        for profileID in Array(closingClients.keys) { await waitForClose(profileID: profileID) }
    }

    private func release(
        profileID: String,
        clientID: ObjectIdentifier,
        evictOnFailure: Bool = false
    ) async {
        guard let runtime = runtimes[profileID], ObjectIdentifier(runtime.client) == clientID else { return }
        guard runtime.leaseCount > 1 else {
            runtimes[profileID] = Runtime(client: runtime.client, leaseCount: 0)
            guard !evictOnFailure, idleTimeout > .zero else {
                await stop(profileID: profileID)
                return
            }
            idleTasks.removeValue(forKey: profileID)?.cancel()
            let timeout = idleTimeout
            idleTasks[profileID] = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.handleIdleTimeout(profileID: profileID, clientID: clientID)
            }
            return
        }
        runtimes[profileID] = Runtime(client: runtime.client, leaseCount: runtime.leaseCount - 1)
        if evictOnFailure {
            await stop(profileID: profileID)
        }
    }

    private func handleIdleTimeout(profileID: String, clientID: ObjectIdentifier) async {
        guard let runtime = runtimes[profileID],
              ObjectIdentifier(runtime.client) == clientID,
              runtime.leaseCount == 0 else {
            return
        }
        idleTasks.removeValue(forKey: profileID)
        await stop(profileID: profileID)
    }

    private func waitForClose(profileID: String) async {
        while let closing = closingClients[profileID] {
            await closing.task.value
            if closingClients[profileID]?.id == closing.id {
                closingClients.removeValue(forKey: profileID)
            }
        }
    }

    /// Coordinates the one-time async start. An actor serializes synchronous
    /// access, but it is still reentrant across `await`; keeping the in-flight
    /// task makes concurrent first connections share one node.
    private func client(for profileID: String) async throws -> any PrivateNetworkClient {
        // close checkpoints Keychain and removes the working directory. Reopening
        // sooner races with that write and can erase the new client's state.
        await waitForClose(profileID: profileID)
        if let runtime = runtimes[profileID] {
            idleTasks.removeValue(forKey: profileID)?.cancel()
            return runtime.client
        }
        if let task = startingClients[profileID] {
            let client = try await task.value
            if runtimes[profileID] == nil {
                runtimes[profileID] = Runtime(client: client, leaseCount: 0)
            }
            return client
        }

        let profileRepository = profileRepository
        let credentialStore = credentialStore
        let factory = factory
        let task: Task<any PrivateNetworkClient, Error> = Task {
            guard let profile = try profileRepository.profile(id: profileID) else {
                throw PrivateNetworkError.profileNotFound(profileID)
            }
            guard profile.isValid else {
                throw PrivateNetworkError.invalidControlURL(profile.controlURL)
            }
            let authKey = try credentialStore.privateNetworkAuthKey(forProfile: profileID)
            guard let authKey, !authKey.isEmpty else {
                throw PrivateNetworkError.missingAuthKey(profileID)
            }
            let client = try await factory.makeClient(for: profile, authKey: authKey)
            do {
                try await client.start()
            } catch {
                // A failed start can already have allocated sockets/state. The
                // registry has not retained the runtime yet, so clean it here.
                await client.close()
                throw error
            }
            return client
        }
        startingClients[profileID] = task
        do {
            let client = try await task.value
            startingClients.removeValue(forKey: profileID)
            if runtimes[profileID] == nil {
                runtimes[profileID] = Runtime(client: client, leaseCount: 0)
            }
            return client
        } catch {
            startingClients.removeValue(forKey: profileID)
            throw error
        }
    }
}

private final class RegistryLease: PrivateNetworkProxyLease, @unchecked Sendable {
    private let rawLease: any PrivateNetworkProxyLease
    private let closeHandler: @Sendable () async -> Void
    private let lock = NSLock()
    private var closed = false

    init(rawLease: any PrivateNetworkProxyLease, closeHandler: @escaping @Sendable () async -> Void) {
        self.rawLease = rawLease
        self.closeHandler = closeHandler
    }

    var endpoint: PrivateNetworkProxyEndpoint { rawLease.endpoint }

    func close() async {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        await rawLease.close()
        await closeHandler()
    }
}

/// The upstream proxy protocol used by a host-scoped route.
public enum RouteProxyProtocol: Sendable, Equatable {
    case socks5(username: String?, password: String?)
    case httpConnect(username: String?, password: String?)
}

/// Minimal local TCP listener which forwards each stream through an upstream
/// proxy. Citadel still sees a normal TCP endpoint, retaining its existing
/// SSH/TOFU implementation and making the route host-scoped.
public final class PrivateNetworkSOCKSProxy: PrivateNetworkProxyLease, @unchecked Sendable {
    private let upstreamHost: String
    private let upstreamPort: Int
    private let proxyProtocol: RouteProxyProtocol
    private let target: SSHEndpoint
    private let queue = DispatchQueue(label: "com.crazyball.Conn.private-network-proxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var closed = false

    public private(set) var endpoint = PrivateNetworkProxyEndpoint(host: "127.0.0.1", port: 0)

    public init(socksHost: String, socksPort: Int, socksCredential: String, target: SSHEndpoint) {
        self.upstreamHost = socksHost
        self.upstreamPort = socksPort
        self.proxyProtocol = .socks5(username: "tsnet", password: socksCredential)
        self.target = target
    }

    /// Creates a host-scoped route through a user-configured HTTP CONNECT or SOCKS5 proxy.
    public init(
        upstreamHost: String,
        upstreamPort: Int,
        proxyProtocol: RouteProxyProtocol,
        target: SSHEndpoint
    ) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.proxyProtocol = proxyProtocol
        self.target = target
    }

    public func start() async throws -> PrivateNetworkSOCKSProxy {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        // This is an in-process transport adapter, never a LAN-facing proxy.
        // `NWListener(..., on: .any)` otherwise listens on every local interface.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        final class ContinuationState: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<UInt16, Error>?
            private var pendingValue: UInt16?
            private var pendingError: Error?

            func setContinuation(_ continuation: CheckedContinuation<UInt16, Error>) {
                lock.withLock {
                    if let value = pendingValue {
                        continuation.resume(returning: value)
                        pendingValue = nil
                    } else if let error = pendingError {
                        continuation.resume(throwing: error)
                        pendingError = nil
                    } else {
                        self.continuation = continuation
                    }
                }
            }

            func resume(returning value: UInt16) {
                lock.withLock {
                    if let continuation {
                        continuation.resume(returning: value)
                        self.continuation = nil
                    } else if pendingError == nil {
                        pendingValue = value
                    }
                }
            }

            func resume(throwing error: Error) {
                lock.withLock {
                    if let continuation {
                        continuation.resume(throwing: error)
                        self.continuation = nil
                    } else if pendingValue == nil {
                        pendingError = error
                    }
                }
            }
        }

        do {
            let state = ContinuationState()
            let port: UInt16 = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    state.setContinuation(continuation)

                    if Task.isCancelled {
                        listener.cancel()
                        state.resume(throwing: CancellationError())
                        return
                    }

                    listener.stateUpdateHandler = { stateUpdate in
                        switch stateUpdate {
                        case .ready:
                            listener.stateUpdateHandler = nil
                            guard let port = listener.port?.rawValue, port != 0 else {
                                state.resume(throwing: PrivateNetworkError.proxyUnavailable)
                                return
                            }
                            state.resume(returning: port)
                        case .failed, .cancelled:
                            listener.stateUpdateHandler = nil
                            state.resume(throwing: PrivateNetworkError.proxyUnavailable)
                        default: break
                        }
                    }
                    // port can be zero until .ready; publishing it sooner makes
                    // Citadel connect to 127.0.0.1:0 and never reach the tailnet.
                    listener.start(queue: queue)
                    if Task.isCancelled {
                        listener.cancel()
                        state.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                listener.cancel()
                state.resume(throwing: CancellationError())
            }
            try Task.checkCancellation()
            endpoint = .init(host: "127.0.0.1", port: Int(port))
            return self
        } catch {
            await close()
            throw error
        }
    }

    public func close() async {
        let active = lock.withLock { () -> [NWConnection] in
            closed = true
            listener?.cancel()
            listener = nil
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        for connection in active { connection.cancel() }
    }

    private func accept(_ incoming: NWConnection) {
        let id = ObjectIdentifier(incoming)
        let accepted = lock.withLock { () -> Bool in
            guard !closed else { return false }
            connections[id] = incoming
            return true
        }
        guard accepted else { incoming.cancel(); return }
        incoming.start(queue: queue)
        Task { [weak self, incoming] in
            var upstream: NWConnection?
            defer {
                incoming.cancel()
                upstream?.cancel()
                self?.remove(incoming, id: id)
            }
            do {
                guard let self else { throw PrivateNetworkError.proxyUnavailable }
                guard let port = NWEndpoint.Port(rawValue: UInt16(self.upstreamPort)) else {
                    throw PrivateNetworkError.proxyUnavailable
                }
                let connection = NWConnection(
                    host: NWEndpoint.Host(self.upstreamHost),
                    port: port,
                    using: .tcp
                )
                upstream = connection
                connection.start(queue: self.queue)
                try await Self.waitUntilReady(connection)
                try await self.performProxyHandshake(connection)
                try await self.pipe(incoming, connection)
            } catch {
                // The defer block closes both sides and removes the connection.
            }
        }
    }

    private func performProxyHandshake(_ connection: NWConnection) async throws {
        switch proxyProtocol {
        case let .socks5(username, password):
            try await performSOCKS5Handshake(connection, username: username, password: password)
        case let .httpConnect(username, password):
            try await performHTTPConnectHandshake(connection, username: username, password: password)
        }
    }

    private func performSOCKS5Handshake(
        _ connection: NWConnection,
        username: String?,
        password: String?
    ) async throws {
        let hasCredentials = username != nil || password != nil
        let usernameData = Data((username ?? "").utf8)
        let passwordData = Data((password ?? "").utf8)
        guard !hasCredentials || (usernameData.count < 256 && passwordData.count < 256) else {
            throw PrivateNetworkError.proxyAuthenticationFailed
        }
        try await send(Data([0x05, 0x01, hasCredentials ? 0x02 : 0x00]), on: connection)
        let method = try await receiveExactly(2, from: connection)
        guard method[0] == 0x05 else { throw PrivateNetworkError.proxyHandshakeFailed }
        if hasCredentials {
            guard method[1] == 0x02 else { throw PrivateNetworkError.proxyAuthenticationFailed }
            try await send(
                Data([0x01, UInt8(usernameData.count)]) + usernameData +
                    Data([UInt8(passwordData.count)]) + passwordData,
                on: connection
            )
            let authResult = try await receiveExactly(2, from: connection)
            guard authResult[1] == 0x00 else { throw PrivateNetworkError.proxyAuthenticationFailed }
        } else {
            guard method[1] == 0x00 else { throw PrivateNetworkError.proxyHandshakeFailed }
        }

        let host = Data(target.host.utf8)
        guard host.count < 256 else { throw PrivateNetworkError.proxyHandshakeFailed }
        try await send(Data([0x05, 0x01, 0x00, 0x03, UInt8(host.count)]) + host + Data([
            UInt8((target.port >> 8) & 0xff), UInt8(target.port & 0xff)
        ]), on: connection)
        let response = try await receiveExactly(4, from: connection)
        guard response[0] == 0x05, response[1] == 0x00 else { throw PrivateNetworkError.proxyHandshakeFailed }
        let addressLength: Int
        switch response[3] {
        case 0x01: addressLength = 4
        case 0x04: addressLength = 16
        case 0x03: addressLength = Int(try await receiveExactly(1, from: connection)[0])
        default: throw PrivateNetworkError.proxyHandshakeFailed
        }
        _ = try await receiveExactly(addressLength + 2, from: connection)
    }

    private func performHTTPConnectHandshake(
        _ connection: NWConnection,
        username: String?,
        password: String?
    ) async throws {
        let host = target.host.contains(":") ? "[\(target.host)]" : target.host
        var request = "CONNECT \(host):\(target.port) HTTP/1.1\r\nHost: \(host):\(target.port)\r\n"
        if let username {
            let credential = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(credential)\r\n"
        }
        request += "\r\n"
        try await send(Data(request.utf8), on: connection)

        let response = try await receiveHTTPHeaders(from: connection)
        guard let responseString = String(data: response, encoding: .utf8),
              let statusLine = responseString.components(separatedBy: "\r\n").first,
              let statusCode = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else { throw PrivateNetworkError.proxyHandshakeFailed }
        if statusCode == 407 { throw PrivateNetworkError.proxyAuthenticationFailed }
        guard (200 ..< 300).contains(statusCode) else { throw PrivateNetworkError.proxyHandshakeFailed }
    }

    private func pipe(_ left: NWConnection, _ right: NWConnection) async throws {
        async let leftToRight: Void = forward(from: left, to: right)
        async let rightToLeft: Void = forward(from: right, to: left)
        _ = try await (leftToRight, rightToLeft)
    }

    private func forward(from source: NWConnection, to destination: NWConnection) async throws {
        while true {
            let data = try await receive(from: source)
            if data.isEmpty { return }
            try await send(data, on: destination)
        }
    }

    private func remove(_ connection: NWConnection, id: ObjectIdentifier) {
        _ = lock.withLock { connections.removeValue(forKey: id) }
        connection.cancel()
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: PrivateNetworkError.proxyUnavailable)
                default: break
                }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive(from connection: NWConnection, maximumLength: Int = 64 * 1024) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if isComplete, content == nil { continuation.resume(returning: Data()) }
                else { continuation.resume(returning: content ?? Data()) }
            }
        }
    }

    private func receiveExactly(_ length: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < length {
            let part = try await receive(from: connection, maximumLength: length - result.count)
            guard !part.isEmpty else { throw PrivateNetworkError.proxyHandshakeFailed }
            result.append(part)
        }
        return result
    }

    private func receiveHTTPHeaders(from connection: NWConnection) async throws -> Data {
        let delimiter = Data("\r\n\r\n".utf8)
        var result = Data()
        while result.range(of: delimiter) == nil {
            let part = try await receive(from: connection)
            guard !part.isEmpty else { throw PrivateNetworkError.proxyHandshakeFailed }
            result.append(part)
            guard result.count <= 64 * 1024 else { throw PrivateNetworkError.proxyHandshakeFailed }
        }
        return result
    }
}

public struct DefaultPrivateNetworkClientFactory: PrivateNetworkClientFactory {
    private let credentialStore: any CredentialStore

    public init(credentialStore: any CredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    public func makeClient(
        for profile: PrivateNetworkProfile,
        authKey: String?
    ) async throws -> any PrivateNetworkClient {
        #if canImport(TailscaleKit)
        return try TailscaleKitPrivateNetworkClient(profile: profile, authKey: authKey, credentialStore: credentialStore)
        #else
        _ = profile
        _ = authKey
        throw PrivateNetworkError.unsupportedOnThisBuild
        #endif
    }
}

#if canImport(TailscaleKit)
import TailscaleKit

private final class TailscaleKitPrivateNetworkClient: PrivateNetworkClient, @unchecked Sendable {
    private let node: TailscaleNode
    private let state: PrivateNetworkNodeState
    private var loopbackConfig: TailscaleNode.LoopbackConfig?
    private(set) var status: PrivateNetworkStatus = .stopped

    init(profile: PrivateNetworkProfile, authKey: String?, credentialStore: any CredentialStore) throws {
        guard profile.isValid else { throw PrivateNetworkError.invalidControlURL(profile.controlURL) }
        state = PrivateNetworkNodeState(profile: profile, credentialStore: credentialStore)
        try state.prepare()
        node = try TailscaleNode(config: Configuration(
            hostName: "Conn-\(profile.id.prefix(24))",
            path: state.directory.path,
            authKey: authKey,
            controlURL: profile.controlURL,
            ephemeral: false
        ), logger: nil)
    }

    func start() async throws {
        status = .starting
        do {
            try await node.up()
            // Save immediately after registration, before a failed SSH attempt or
            // force-quit can discard the device identity.
            try state.checkpoint()
            loopbackConfig = try await node.loopback()
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func openTCPProxy(to endpoint: SSHEndpoint) async throws -> any PrivateNetworkProxyLease {
        guard let loopbackConfig,
              let host = loopbackConfig.ip,
              let port = loopbackConfig.port
        else { throw PrivateNetworkError.proxyUnavailable }
        return try await PrivateNetworkSOCKSProxy(
            socksHost: host,
            socksPort: port,
            socksCredential: loopbackConfig.proxyCredential,
            target: endpoint
        ).start()
    }

    func close() async {
        status = .stopped
        try? await node.close()
        do {
            try state.checkpoint()
            try state.removeWorkingDirectory()
        } catch {
            // Preserve the protected working copy when Keychain is unavailable
            // (e.g. the device just locked); never erase the only current identity.
        }
    }
}
#endif
