import ConnKit
import ConnSSH
import Foundation
import OSLog

private let tmuxProviderLogger = Logger(
    subsystem: "com.crazyball.Conn",
    category: "TmuxProvider"
)

/// Provider-owned tmux configuration. Shared layers carry the payload opaquely;
/// only this provider is allowed to interpret it.
public struct TmuxProviderConfiguration: Codable, Sendable, Equatable {
    public let locator: TmuxServerLocator

    public init(locator: TmuxServerLocator = .default) {
        self.locator = locator
    }
}

/// The first attachment renderer is deliberately byte-oriented. A later native pane
/// renderer can be introduced by adding a new payload version without changing the
/// provider-neutral descriptor envelope.
public enum TmuxRenderMode: String, Codable, Sendable, Equatable {
    case passthroughPTY
}

public struct TmuxWorkspaceInstancePayload: Codable, Sendable, Equatable {
    public let serverInstanceToken: TmuxServerInstanceToken

    public init(serverInstanceToken: TmuxServerInstanceToken) {
        self.serverInstanceToken = serverInstanceToken
    }
}

public struct TmuxAttachmentPayload: Codable, Sendable, Equatable {
    public let lastKnownSessionName: String?
    public let renderMode: TmuxRenderMode

    public init(
        lastKnownSessionName: String? = nil,
        renderMode: TmuxRenderMode = .passthroughPTY
    ) {
        self.lastKnownSessionName = lastKnownSessionName
        self.renderMode = renderMode
    }
}

public enum TmuxProviderError: Error, Sendable, Equatable {
    case malformedProbeOutput
    case unsupportedAttachmentMode(TmuxRenderMode)
    case attachmentHandshakeFailed
}

package enum TmuxHandshakeKind: String, Sendable {
    case attachment = "__CONN_TMUX_ATTACH_v1__"
    case control = "__CONN_TMUX_CONTROL_v1__"
}

/// Prints one provider-owned frame, then starts the long-lived tmux process as a
/// separate shell command. The separator must be a real newline: a literal `\n`
/// outside the printf format would turn the tmux argv into extra printf operands.
package func tmuxHandshakeScript(
    kind: TmuxHandshakeKind,
    nonce: String,
    invocation: String
) -> String {
    "printf '\(kind.rawValue) nonce="
        + POSIXShellArgument.encode(nonce)
        + " tty=%s pid=%s\\n' \"$(tty)\" \"$$\"\n"
        + invocation
}

/// tmux release versions commonly carry suffixes such as `3.5a` and may be prefixed by
/// distributor text. Extract numeric runs instead of requiring every dot-separated token
/// to be an integer; otherwise modern releases silently fall back to the very expensive
/// legacy per-field snapshot codec during attachment startup.
package func tmuxProtocolDialectCandidate(for version: String) -> TmuxProtocolDialect {
    let numbers = version
        .split(whereSeparator: { !$0.isNumber })
        .compactMap { Int($0) }
    let major = numbers.first ?? 0
    let minor = numbers.dropFirst().first ?? 0
    let modernGuards = major > 2 || (major == 2 && minor >= 7)
    let quoted = major > 3 || (major == 3 && minor >= 1)
    return TmuxProtocolDialect(
        commandGuardShape: modernGuards ? .threeFields : .twoFields,
        snapshotCodec: quoted ? .quoted : .legacyPerField
    )
}

/// Provider entry point for the generic persistent-terminal registry.
///
/// This implementation owns platform routing, safe static probing, workspace identity
/// and the byte-terminal attach path. Control Mode negotiation remains a separate runtime
/// phase: it is never inferred from a version string and never emulated with `openShell`.
public struct TmuxProvider: PersistentTerminalCatalogProvider {
    public static let providerID = "tmux"
    public static let configurationVersion = 1
    public static let workspaceInstancePayloadVersion = 1
    public static let attachmentPayloadVersion = 1
    private static let controlRuntimeRegistry = TmuxProviderControlRuntimeRegistry()
    private static let attachmentGenerations = TmuxAttachmentGenerationSource()
    private static let staticRuntimeCache = TmuxStaticRuntimeCache()

    public let descriptor: PersistentTerminalProviderDescriptor
    public let defaultConfiguration: PersistentTerminalConfiguration

    public init() {
        let configuration = TmuxProviderConfiguration()
        let configurationData: Data
        do {
            configurationData = try JSONEncoder().encode(configuration)
        } catch {
            preconditionFailure("built-in tmux configuration must encode: \(error)")
        }
        defaultConfiguration = PersistentTerminalConfiguration(
            providerID: Self.providerID,
            configurationKey: configuration.locator.configurationKey,
            payloadVersion: Self.configurationVersion,
            providerPayload: configurationData
        )
        descriptor = PersistentTerminalProviderDescriptor(
            id: Self.providerID,
            displayName: "tmux",
            supportedPlatforms: [.linux, .macOS],
            supportedConfigurationVersions: [Self.configurationVersion],
            supportedWorkspaceInstancePayloadVersions: [Self.workspaceInstancePayloadVersion],
            supportedAttachmentPayloadVersions: [Self.attachmentPayloadVersion],
            potentialFeatures: [
                .workspaceDiscovery,
                .workspaceCreation,
                .workspaceRename,
                .workspaceDestruction,
                .eventStreaming,
                .dynamicMetadataSubscriptions,
                .clientInspection,
                .hierarchicalWindows,
                .hierarchicalPanes,
                .readOnlyAttach,
                .snapshotPreview,
            ]
        )
    }

    public func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
        guard descriptor.supportedPlatforms.contains(context.platformProfile.kind) else {
            return PersistentTerminalAvailability(
                state: .unsupported,
                issue: .unsupportedPlatform
            )
        }

        let configuration = try decodeConfiguration(from: context.backendConfiguration)
        let runtime: TmuxStaticRuntime
        do {
            runtime = try await resolveRuntime(configuration: configuration, in: context)
        } catch let issue as PersistentTerminalError {
            return PersistentTerminalAvailability(state: .unavailable, issue: issue)
        }

        guard let token = try await readServerIdentity(using: runtime, in: context) else {
            return PersistentTerminalAvailability(
                state: .degraded,
                effectiveFeatures: [.workspaceDiscovery, .workspaceCreation],
                issue: .serverUnavailable
            )
        }

        let instance = try makeProviderInstance(token: token)
        return PersistentTerminalAvailability(
            state: .available,
            effectiveFeatures: [
                .workspaceDiscovery,
                .workspaceCreation,
                .workspaceRename,
                .workspaceDestruction,
            ],
            instance: instance
        )
    }

    public func listWorkspaces(in context: PersistentTerminalContext) async throws -> [RemoteWorkspaceSummary] {
        let configuration = try decodeConfiguration(from: context.backendConfiguration)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        let catalog: TmuxWorkspaceCatalogObservation?
        switch tmuxProtocolDialectCandidate(for: runtime.version).snapshotCodec {
        case .quoted:
            catalog = try await readQuotedWorkspaceCatalog(using: runtime, in: context)
        case .legacyPerField:
            catalog = try await readLegacyWorkspaceCatalog(using: runtime, in: context)
        }
        guard let catalog else { return [] }

        let observedAt = Date()
        let workspacePayload = try JSONEncoder().encode(
            TmuxWorkspaceInstancePayload(serverInstanceToken: catalog.token)
        )
        var summaries: [RemoteWorkspaceSummary] = []
        summaries.reserveCapacity(catalog.sessions.count)
        for session in catalog.sessions {
            summaries.append(RemoteWorkspaceSummary(
                workspace: RemoteWorkspaceRef(
                    workspaceID: session.id.rawValue,
                    instancePayloadVersion: Self.workspaceInstancePayloadVersion,
                    providerInstancePayload: workspacePayload
                ),
                name: session.name,
                occupancy: RemoteWorkspaceOccupancy(
                    affectedAttachmentCount: nil,
                    observedAt: observedAt,
                    freshness: .unknown
                )
            ))
        }
        return summaries
    }

    public func createWorkspace(
        _ request: CreateWorkspaceRequest,
        in context: PersistentTerminalContext
    ) async throws -> RemoteWorkspaceSummary {
        let configuration = try decodeConfiguration(from: context.backendConfiguration)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        let name = try request.name.map(TmuxName.init)

        if let token = try await readServerIdentity(using: runtime, in: context) {
            let scope = try makeScope(context: context, token: token)
            let executor = TmuxOneShotOperationExecutor(
                session: context.session,
                runtime: runtime.runtime,
                executable: runtime.executable,
                locator: configuration.locator,
                scope: scope,
                nonceFactory: { try Self.makeNonce() }
            )
            let result = try await executor.execute(
                TmuxOperationRequest(
                    scope: scope,
                    operation: .createSession(name: name)
                ),
                timeout: .seconds(30)
            )
            let created = try decodeCreatedWorkspace(result.output)
            return try workspaceSummary(
                sessionID: created.sessionID,
                name: created.name,
                token: token
            )
        }

        // Bootstrap is one remote invocation. It re-checks that the locator is still
        // server/session-empty, creates the first session, and prints the new session ID
        // and identity from the same tmux server command queue. A second invocation would
        // have a check/use race and could bind the descriptor to another client's server.
        let bootstrap = try await bootstrapCreateWorkspace(
            name: name,
            runtime: runtime,
            configuration: configuration,
            in: context
        )
        return try workspaceSummary(
            sessionID: bootstrap.sessionID,
            name: bootstrap.name,
            token: bootstrap.token
        )
    }

    public func renameWorkspace(
        _ workspace: RemoteWorkspaceRef,
        to newName: String,
        in context: PersistentTerminalContext
    ) async throws {
        let name = try TmuxName(newName)
        let configuration = try decodeConfiguration(from: context.backendConfiguration)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        let token = try decodeToken(from: workspace)
        let currentToken = try await readServerIdentity(using: runtime, in: context)
        guard currentToken == token else { throw PersistentTerminalError.serverInstanceChanged }
        let scope = try makeScope(context: context, token: token)
        let executor = TmuxOneShotOperationExecutor(
            session: context.session,
            runtime: runtime.runtime,
            executable: runtime.executable,
            locator: configuration.locator,
            scope: scope,
            nonceFactory: { try Self.makeNonce() }
        )
        let sessionID = try decodeSessionID(workspace.workspaceID)
        _ = try await executor.execute(
            TmuxOperationRequest(
                scope: scope,
                operation: .renameSession(
                    sessionID,
                    to: name
                )
            ),
            timeout: .seconds(30)
        )
    }

    public func destroyWorkspace(
        _ workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) async throws {
        let configuration = try decodeConfiguration(from: context.backendConfiguration)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        let token = try decodeToken(from: workspace)
        let currentToken = try await readServerIdentity(using: runtime, in: context)
        guard currentToken == token else { throw PersistentTerminalError.serverInstanceChanged }
        let scope = try makeScope(context: context, token: token)
        let executor = TmuxOneShotOperationExecutor(
            session: context.session,
            runtime: runtime.runtime,
            executable: runtime.executable,
            locator: configuration.locator,
            scope: scope,
            nonceFactory: { try Self.makeNonce() }
        )
        let sessionID = try decodeSessionID(workspace.workspaceID)
        _ = try await executor.execute(
            TmuxOperationRequest(
                scope: scope,
                operation: .killSession(sessionID)
            ),
            timeout: .seconds(30)
        )
    }

    public func makeAttachmentDescriptor(
        to workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) throws -> PersistentAttachmentDescriptor {
        _ = try decodeToken(from: workspace)
        _ = try decodeSessionID(workspace.workspaceID)
        let payload = try JSONEncoder().encode(TmuxAttachmentPayload())
        return PersistentAttachmentDescriptor(
            providerID: Self.providerID,
            configuration: context.backendConfiguration,
            workspace: workspace,
            payloadVersion: Self.attachmentPayloadVersion,
            providerPayload: payload
        )
    }

    public func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment {
        _ = reason
        guard descriptor.providerID == Self.providerID,
              descriptor.configuration == context.backendConfiguration,
              descriptor.payloadVersion == Self.attachmentPayloadVersion
        else {
            if descriptor.payloadVersion != Self.attachmentPayloadVersion {
                throw PersistentTerminalError.unsupportedDescriptorVersion(
                    providerID: Self.providerID,
                    component: .attachment,
                    version: descriptor.payloadVersion
                )
            }
            throw PersistentTerminalError.invalidConfiguration
        }
        let payload: TmuxAttachmentPayload
        do {
            payload = try JSONDecoder().decode(TmuxAttachmentPayload.self, from: descriptor.providerPayload)
        } catch {
            throw PersistentTerminalError.invalidConfiguration
        }
        guard payload.renderMode == .passthroughPTY else {
            throw TmuxProviderError.unsupportedAttachmentMode(payload.renderMode)
        }
        let runtimeAttachmentID = UUID().uuidString
        let attachmentGeneration = await Self.attachmentGenerations.next()

        let configuration = try decodeConfiguration(from: context.backendConfiguration)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        let expectedToken = try decodeToken(from: descriptor.workspace)
        guard try await readServerIdentity(using: runtime, in: context) == expectedToken else {
            throw PersistentTerminalError.serverInstanceChanged
        }
        let sessionID = try decodeSessionID(descriptor.workspace.workspaceID)
        let controlScope = try makeScope(context: context, token: expectedToken)
        let startup = TmuxAttachmentStartupTransaction()
        let controlFailure = TmuxAttachmentStartupFailureBox()
        let nonce = try Self.makeNonce()
        let dialect = tmuxProtocolDialectCandidate(for: runtime.version)
        let oneShotExecutor = TmuxOneShotReadOnlyCommandExecutor(
            session: context.session,
            runtime: runtime.runtime,
            executable: runtime.executable,
            locator: configuration.locator,
            scope: controlScope,
            nonceFactory: { try Self.makeNonce() }
        )
        let captureExecutor = TmuxStreamingPaneHistoryCaptureExecutor(
            session: context.session,
            runtime: runtime.runtime,
            executable: runtime.executable,
            locator: configuration.locator,
            scope: controlScope,
            nonceFactory: { try Self.makeNonce() }
        )

        let pipeline = TerminalStartupPipeline(steps: [
            .init(id: .controlPlane) { [self] in
                guard let lease = await preflightControlMode(
                    sessionID: sessionID,
                    runtime: runtime,
                    configuration: configuration,
                    context: context,
                    scope: controlScope,
                    terminalSize: terminalSize,
                    failureBox: controlFailure,
                    maximumAttempts: 2
                ) else {
                    throw await controlFailure.failure
                        ?? PersistentTerminalError.controlModeUnavailable
                }
                await startup.storeControlPreflight(lease)
                return TerminalStartupRollback {
                    await startup.rollbackControlPreflight()
                }
            },
            .init(id: .remoteProcess) { [self] in
                let controlLease = try await startup.controlPreflight()
                let clientFlags = await controlLease.runtime.capabilities.supportedClientFlags
                    .intersection([.activePane, .ignoreSize])
                var attachArguments = ["attach-session"]
                if !clientFlags.isEmpty {
                    attachArguments += [
                        "-f",
                        clientFlags.sorted { $0.rawValue < $1.rawValue }
                            .map(\.rawValue)
                            .joined(separator: ","),
                    ]
                }
                attachArguments += ["-t", sessionID.rawValue]
                let invocation = tmuxScript(
                    executable: runtime.executable,
                    locator: configuration.locator,
                    arguments: attachArguments
                )
                let script = tmuxHandshakeScript(
                    kind: .attachment,
                    nonce: nonce.value,
                    invocation: invocation
                )
                let command = try runtime.runtime.invocation(for: script)
                let process = try await context.session.openProcess(
                    RemoteProcessRequest(
                        command: command,
                        terminal: RemoteTerminalRequest(
                            type: "xterm-256color",
                            size: terminalSize
                        )
                    )
                )
                await startup.storeProcess(process)
                return TerminalStartupRollback {
                    await startup.rollbackProcess()
                }
            },
            .init(id: .byteTerminal) {
                let process = try await startup.process()
                let attachment = try await TmuxPassthroughAttachment.open(
                    descriptor: descriptor,
                    process: process,
                    nonce: nonce,
                    runtimeAttachmentID: runtimeAttachmentID,
                    attachmentGeneration: attachmentGeneration,
                    interactionFactory: { tty, processID in
                        let historyBackend = TmuxOneShotInteractionBackend(
                            executor: oneShotExecutor,
                            captureExecutor: captureExecutor,
                            scope: controlScope,
                            dialect: dialect,
                            attachmentID: runtimeAttachmentID,
                            attachmentGeneration: attachmentGeneration,
                            requestedSessionID: sessionID,
                            tty: tty,
                            processID: processID,
                            nonceFactory: { try Self.makeNonce() }
                        )
                        return TmuxInteractionFacet(
                            attachmentGeneration: attachmentGeneration,
                            historyBackend: historyBackend
                        )
                    }
                )
                await startup.storeAttachment(attachment)
                return TerminalStartupRollback {
                    await startup.rollbackAttachment()
                }
            },
            .init(id: "tmux.server-identity") { [self] in
                guard try await readServerIdentity(using: runtime, in: context) == expectedToken else {
                    throw PersistentTerminalError.serverInstanceChanged
                }
                return nil
            },
            .init(id: .identityBinding) { [self] in
                let attachment = try await startup.attachment()
                guard let identity = attachment.processIdentity else {
                    throw TmuxProviderError.attachmentHandshakeFailed
                }
                let controlLease = try await startup.consumeControlPreflight()
                let bindingFailure = TmuxAttachmentStartupFailureBox()
                guard let interactionLease = await Self.controlRuntimeRegistry.acquireAttachment(
                    controlLease,
                    attachmentID: runtimeAttachmentID,
                    attachmentGeneration: attachmentGeneration,
                    requestedSessionID: sessionID,
                    makeHub: { [self] controlRuntime in
                        do {
                            return try await makeControlHub(
                                sessionID: sessionID,
                                controlRuntime: controlRuntime,
                                scope: controlScope,
                                attachmentIdentity: identity,
                                attachmentID: runtimeAttachmentID
                            )
                        } catch {
                            await bindingFailure.record(error)
                            return nil
                        }
                    },
                    resolveIdentity: { [self] controlRuntime in
                        do {
                            return try await resolveControlIdentity(
                                sessionID: sessionID,
                                runtime: controlRuntime,
                                scope: controlScope,
                                attachmentIdentity: identity,
                                attachmentID: runtimeAttachmentID
                            )
                        } catch {
                            await bindingFailure.record(error)
                            return nil
                        }
                    }
                ) else {
                    let failure = await bindingFailure.failure
                    tmuxProviderLogger.error(
                        "Control registry did not publish attachment lease; recorded failure type=\(failure.map { String(reflecting: type(of: $0)) } ?? "none", privacy: .public)"
                    )
                    throw failure ?? PersistentTerminalError.controlModeUnavailable
                }
                do {
                    guard await Self.controlRuntimeRegistry.hasReadyControlRuntime(
                        interactionLease
                    ) else {
                        tmuxProviderLogger.error(
                            "Control registry published an attachment lease without a ready runtime"
                        )
                        throw PersistentTerminalError.controlModeUnavailable
                    }
                    _ = try await Self.controlRuntimeRegistry.resolveInteractionContext(
                        interactionLease,
                        refreshIfNeeded: false
                    )
                    await attachment.installControlLease(interactionLease)
                    await startup.markControlBound()
                } catch {
                    tmuxProviderLogger.error(
                        "Attachment lease readiness validation failed; type=\(String(reflecting: type(of: error)), privacy: .public)"
                    )
                    await Self.controlRuntimeRegistry.release(interactionLease)
                    throw error
                }
                return nil
            },
            .init(id: .readiness) {
                try await startup.validateReady()
                return nil
            },
        ])
        try await pipeline.run()
        return try await startup.finishedAttachment()
    }

    public func openCatalog(
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalCatalogAttachment {
        let configuration = try decodeConfiguration(from: context.backendConfiguration)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        guard let token = try await readServerIdentity(using: runtime, in: context) else {
            let observedAt = Date()
            return TmuxStaticCatalogAttachment(
                snapshot: PersistentWorkspaceCatalogSnapshot(
                    providerID: Self.providerID,
                    configurationKey: context.backendConfiguration.configurationKey,
                    instance: nil,
                    workspaces: [],
                    freshness: .snapshot(observedAt: observedAt),
                    observedAt: observedAt
                )
            )
        }
        let workspaces = try await listWorkspaces(in: context)
        guard let firstWorkspace = workspaces.first else {
            return TmuxStaticCatalogAttachment(
                snapshot: try makeCatalogSnapshot(
                    token: token,
                    workspaces: [],
                    configurationKey: context.backendConfiguration.configurationKey,
                    freshness: .snapshot(observedAt: Date())
                )
            )
        }
        guard try decodeToken(from: firstWorkspace.workspace) == token else {
            throw PersistentTerminalError.serverInstanceChanged
        }
        let scope = try makeScope(context: context, token: token)
        let sessionID = try decodeSessionID(firstWorkspace.workspace.workspaceID)
        guard let preflight = await preflightControlMode(
            sessionID: sessionID,
            runtime: runtime,
            configuration: configuration,
            context: context,
            scope: scope,
            terminalSize: .init(cols: 80, rows: 24)
        ) else {
            return TmuxStaticCatalogAttachment(
                snapshot: try makeCatalogSnapshot(
                    token: token,
                    workspaces: workspaces,
                    configurationKey: context.backendConfiguration.configurationKey,
                    freshness: .snapshot(observedAt: Date())
                )
            )
        }
        guard let lease = await Self.controlRuntimeRegistry.acquireCatalog(
            preflight,
            makeHub: { [self] controlRuntime in
                await makeCatalogHub(
                    scope: scope,
                    controlRuntime: controlRuntime
                )
            }
        ) else {
            return TmuxStaticCatalogAttachment(
                snapshot: try makeCatalogSnapshot(
                    token: token,
                    workspaces: workspaces,
                    configurationKey: context.backendConfiguration.configurationKey,
                    freshness: .snapshot(observedAt: Date())
                )
            )
        }
        let controlCapabilities = await lease.runtime.capabilities
        let controlConfiguration = await lease.runtime.configuration
        return TmuxWorkspaceCatalogAttachment(
            providerID: Self.providerID,
            configurationKey: context.backendConfiguration.configurationKey,
            instanceToken: token,
            lease: lease,
            controlCapabilities: controlCapabilities,
            controlConfiguration: controlConfiguration
        )
    }

    /// Completes the required management-plane handshake after the data client has a
    /// verified tty/PID. Returning nil fails and rolls back the complete attachment startup.
    private func makeControlHub(
        sessionID: TmuxSessionID,
        controlRuntime: TmuxControlRuntime,
        scope: TmuxOperationScope,
        attachmentIdentity: (tty: String, pid: Int32),
        attachmentID: String
    ) async throws -> TmuxProviderControlSetup {
        let registeredClients = try await waitForRegisteredAttachmentClients(
            sessionID: sessionID,
            controlRuntime: controlRuntime,
            attachmentIdentity: attachmentIdentity
        )
        let controlClient = registeredClients.controlClient
        let dataClient = registeredClients.dataClient

        let identity = TmuxControlInteractiveIdentity(
                attachmentID: attachmentID,
                clientID: dataClient,
                requestedSessionID: sessionID
            )
        let snapshot = try await controlRuntime.loadSnapshot(
                reason: .userRequested,
                identities: [identity],
                controlClientID: controlClient,
                timeout: .seconds(5)
            )
        await controlRuntime.setControlClientID(controlClient)
        let adapter = TmuxControlHubRuntimeAdapter(
                initialScope: scope,
                controlClients: controlRuntime,
                snapshots: controlRuntime,
                lifecycle: TmuxControlRuntimeLifecycleBridge(
                    runtime: controlRuntime,
                    registry: Self.controlRuntimeRegistry,
                    scope: scope
                )
            )
        let hub = try TmuxControlHub(
                scope: scope,
                initialSnapshot: snapshot,
                adapter: adapter
            )
        return TmuxProviderControlSetup(hub: hub, identity: identity)
    }

    /// The shell handshake is intentionally emitted before `exec tmux attach-session`.
    /// Its tty/PID is authoritative, but the tmux server may publish that client a few
    /// scheduling ticks later. Poll the authoritative Control Mode snapshot for a short,
    /// bounded interval instead of treating that normal registration race as a missing
    /// required component.
    private func waitForRegisteredAttachmentClients(
        sessionID: TmuxSessionID,
        controlRuntime: TmuxControlRuntime,
        attachmentIdentity: (tty: String, pid: Int32)
    ) async throws -> (controlClient: TmuxClientID, dataClient: TmuxClientID) {
        for attempt in 0 ..< 10 {
            try Task.checkCancellation()
            let snapshot = try await controlRuntime.loadSnapshot(
                reason: .userRequested,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(5)
            )
            let controlClient = snapshot.clients.values.first(where: {
                $0.tty == controlRuntime.processIdentity.tty
                    && $0.id.processID == controlRuntime.processIdentity.processID
                    && $0.kind == .controlMode
            })?.id
            let dataClient = snapshot.clients.values.first(where: {
                $0.tty == attachmentIdentity.tty
                    && $0.id.processID == attachmentIdentity.pid
                    && $0.sessionID == sessionID
                    && $0.kind == .interactiveTerminal
            })?.id
            if let controlClient, let dataClient {
                return (controlClient, dataClient)
            }
            if attempt == 9 {
                let observed = snapshot.clients.values
                    .map {
                        let tty = $0.tty ?? "none"
                        let processID = $0.id.processID.map(String.init) ?? "none"
                        return "\($0.kind):\(tty):\(processID):\($0.sessionID.rawValue)"
                    }
                    .sorted()
                    .joined(separator: ",")
                tmuxProviderLogger.error(
                    "Attachment client was not registered; expected tty=\(attachmentIdentity.tty, privacy: .public) pid=\(attachmentIdentity.pid, privacy: .public) session=\(sessionID.rawValue, privacy: .public); observed=\(observed, privacy: .public)"
                )
            }
            if attempt < 9 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw PersistentTerminalError.controlModeUnavailable
    }

    private func makeCatalogHub(
        scope: TmuxOperationScope,
        controlRuntime: TmuxControlRuntime
    ) async -> TmuxControlHub? {
        do {
            let firstSnapshot = try await controlRuntime.loadSnapshot(
                reason: .userRequested,
                identities: [],
                controlClientID: nil,
                timeout: .seconds(5)
            )
            guard let controlClient = firstSnapshot.clients.values.first(where: {
                $0.tty == controlRuntime.processIdentity.tty
                    && $0.id.processID == controlRuntime.processIdentity.processID
                    && $0.kind == .controlMode
            })?.id else {
                return nil
            }
            let snapshot = try await controlRuntime.loadSnapshot(
                reason: .userRequested,
                identities: [],
                controlClientID: controlClient,
                timeout: .seconds(5)
            )
            await controlRuntime.setControlClientID(controlClient)
            let adapter = TmuxControlHubRuntimeAdapter(
                initialScope: scope,
                controlClients: controlRuntime,
                snapshots: controlRuntime,
                lifecycle: TmuxControlRuntimeLifecycleBridge(
                    runtime: controlRuntime,
                    registry: Self.controlRuntimeRegistry,
                    scope: scope
                )
            )
            let hub = try TmuxControlHub(
                scope: scope,
                initialSnapshot: snapshot,
                adapter: adapter
            )
            await hub.startEventStream(controlRuntime.events)
            return hub
        } catch {
            return nil
        }
    }

    private func resolveControlIdentity(
        sessionID: TmuxSessionID,
        runtime: TmuxControlRuntime,
        scope: TmuxOperationScope,
        attachmentIdentity: (tty: String, pid: Int32),
        attachmentID: String
    ) async throws -> TmuxControlInteractiveIdentity {
        let client = try await waitForRegisteredDataClient(
            sessionID: sessionID,
            runtime: runtime,
            scope: scope,
            attachmentIdentity: attachmentIdentity
        )
        let identity = TmuxControlInteractiveIdentity(
            attachmentID: attachmentID,
            clientID: client,
            requestedSessionID: sessionID
        )
        _ = try await runtime.loadSnapshot(
            scope: scope,
            reason: .userRequested,
            identities: [identity]
        )
        return identity
    }

    private func waitForRegisteredDataClient(
        sessionID: TmuxSessionID,
        runtime: TmuxControlRuntime,
        scope: TmuxOperationScope,
        attachmentIdentity: (tty: String, pid: Int32)
    ) async throws -> TmuxClientID {
        for attempt in 0 ..< 10 {
            try Task.checkCancellation()
            let snapshot = try await runtime.loadSnapshot(
                scope: scope,
                reason: .userRequested,
                identities: []
            )
            if let client = snapshot.clients.values.first(where: {
                $0.tty == attachmentIdentity.tty
                    && $0.id.processID == attachmentIdentity.pid
                    && $0.sessionID == sessionID
                    && $0.kind == .interactiveTerminal
            })?.id {
                return client
            }
            if attempt < 9 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw PersistentTerminalError.controlModeUnavailable
    }

    private func preflightControlMode(
        sessionID: TmuxSessionID,
        runtime: TmuxStaticRuntime,
        configuration: TmuxProviderConfiguration,
        context: PersistentTerminalContext,
        scope: TmuxOperationScope,
        terminalSize: TermSize,
        failureBox: TmuxAttachmentStartupFailureBox? = nil,
        maximumAttempts: Int = 1
    ) async -> TmuxProviderControlRuntimeLease? {
        for _ in 0 ..< max(1, maximumAttempts) {
            guard !Task.isCancelled else { return nil }
            let controlRuntime = await Self.controlRuntimeRegistry.acquireRuntime(for: scope) {
                do {
                    return try await openControlRuntime(
                        sessionID: sessionID,
                        runtime: runtime,
                        configuration: configuration,
                        context: context,
                        scope: scope,
                        terminalSize: terminalSize
                    )
                } catch {
                    if let failureBox {
                        await failureBox.record(error)
                    }
                    return nil
                }
            }
            if let controlRuntime { return controlRuntime }
        }
        return nil
    }

    private func openControlRuntime(
        sessionID: TmuxSessionID,
        runtime: TmuxStaticRuntime,
        configuration: TmuxProviderConfiguration,
        context: PersistentTerminalContext,
        scope: TmuxOperationScope,
        terminalSize: TermSize
    ) async throws -> TmuxControlRuntime {
        let controlScript = tmuxScript(
            executable: runtime.executable,
            locator: configuration.locator,
            arguments: ["-CC", "attach-session", "-t", sessionID.rawValue]
        )
        let controlNonce = try Self.makeNonce().value
        let controlWrapper = tmuxHandshakeScript(
            kind: .control,
            nonce: controlNonce,
            invocation: controlScript
        )
        let command = try runtime.runtime.invocation(for: controlWrapper)
        let channel = try await context.session.openProcess(
            RemoteProcessRequest(
                command: command,
                terminal: RemoteTerminalRequest(type: "xterm-256color", size: terminalSize)
            )
        )

        do {
            let controlChannel = try await TmuxControlHandshakeChannel.open(
                process: channel,
                nonce: controlNonce
            )
            let control = try TmuxControlRuntime(
                channel: controlChannel,
                scope: scope,
                dialect: tmuxProtocolDialectCandidate(for: runtime.version),
                processIdentity: .init(
                    tty: controlChannel.processIdentity.tty,
                    processID: controlChannel.processIdentity.pid
                )
            )
            try await control.start(timeout: .seconds(5))
            return control
        } catch {
            await channel.close()
            throw error
        }
    }

    private struct TmuxStaticRuntime: Sendable {
        let configuration: TmuxProviderConfiguration
        let runtime: PreparedRemoteScriptRuntime
        let executable: TmuxExecutablePath
        let version: String
    }

    /// Static executable/version discovery is stable for one concrete pooled SSH
    /// session. This short-lived provider cache lets selection, creation and attachment
    /// startup share one probe without persisting capability state or crossing a
    /// ConnectionManager session replacement.
    private struct TmuxStaticRuntimeCacheKey: Hashable, @unchecked Sendable {
        let sessionObjectID: ObjectIdentifier
        let connectionIdentity: SSHConnectionIdentity
        let configuration: PersistentTerminalConfiguration

        init(context: PersistentTerminalContext) {
            sessionObjectID = ObjectIdentifier(context.session)
            connectionIdentity = context.connectionIdentity
            configuration = context.backendConfiguration
        }
    }

    private actor TmuxStaticRuntimeCache {
        private struct Entry: Sendable {
            let runtime: TmuxStaticRuntime
            // Retaining the exact session for the short cache lifetime prevents its
            // ObjectIdentifier from being recycled for a newly connected session.
            let session: any SSHSession
            var lastAccess: Date
        }

        private let lifetime: TimeInterval = 120
        private let maximumEntryCount = 32
        private var entries: [TmuxStaticRuntimeCacheKey: Entry] = [:]

        func value(for key: TmuxStaticRuntimeCacheKey) -> TmuxStaticRuntime? {
            let now = Date()
            entries = entries.filter { now.timeIntervalSince($0.value.lastAccess) <= lifetime }
            guard var entry = entries[key] else { return nil }
            entry.lastAccess = now
            entries[key] = entry
            return entry.runtime
        }

        func insert(
            _ runtime: TmuxStaticRuntime,
            session: any SSHSession,
            for key: TmuxStaticRuntimeCacheKey
        ) {
            let now = Date()
            entries[key] = Entry(runtime: runtime, session: session, lastAccess: now)
            guard entries.count > maximumEntryCount,
                  let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
            else { return }
            entries[oldest] = nil
        }
    }

    private struct TmuxWorkspaceCatalogObservation: Sendable {
        struct Session: Sendable {
            let id: TmuxSessionID
            let name: String
        }

        let token: TmuxServerInstanceToken
        let sessions: [Session]
    }

    private struct BootstrapResult: Sendable {
        let sessionID: TmuxSessionID
        let name: String
        let token: TmuxServerInstanceToken
    }

    private struct CreatedWorkspace: Sendable {
        let sessionID: TmuxSessionID
        let name: String
    }

    private func bootstrapCreateWorkspace(
        name: TmuxName?,
        runtime: TmuxStaticRuntime,
        configuration: TmuxProviderConfiguration,
        in context: PersistentTerminalContext
    ) async throws -> BootstrapResult {
        let list = tmuxScript(
            executable: runtime.executable,
            locator: configuration.locator,
            arguments: ["list-sessions", "-F", "#{session_id}"]
        )
        var newArguments = [
            "new-session", "-d", "-P", "-F", "#{session_id}\t#{session_name}",
        ]
        if let name { newArguments += ["-s", name.value] }
        let create = tmuxScript(
            executable: runtime.executable,
            locator: configuration.locator,
            arguments: newArguments
        )
        let identity = tmuxScript(
            executable: runtime.executable,
            locator: configuration.locator,
            arguments: ["display-message", "-p", "#{socket_path}\\n#{pid}\\n#{start_time}"]
        )
        let script = "set -eu\n"
            + "if sessions=$(\(list) 2>/dev/null); then\n"
            + "    if [ -n \"$sessions\" ]; then exit 75; fi\n"
            + "fi\n"
            + "session_id=$(\(create))\n"
            + "printf '%s\\n' \"$session_id\"\n"
            + identity + "\n"
        let result = try await execute(script: script, runtime: runtime.runtime, in: context)
        guard result.isSuccess else {
            if result.exitCode == 75 {
                throw PersistentTerminalError.bootstrapPreconditionChanged
            }
            throw commandRejected(result)
        }
        var lines = String(decoding: result.stdout, as: UTF8.self)
            .components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 4,
              let created = try? decodeCreatedWorkspace(Data(lines[0].utf8)),
              let pid = Int32(lines[2]),
              let start = Int64(lines[3]),
              !lines[1].isEmpty
        else {
            throw TmuxProviderError.malformedProbeOutput
        }
        do {
            return BootstrapResult(
                sessionID: created.sessionID,
                name: created.name,
                token: try TmuxServerInstanceToken(
                    resolvedSocketPath: lines[1],
                    serverPID: pid,
                    serverStartTime: start
                )
            )
        } catch {
            throw TmuxProviderError.malformedProbeOutput
        }
    }

    private func decodeConfiguration(
        from configurationEnvelope: PersistentTerminalConfiguration
    ) throws -> TmuxProviderConfiguration {
        guard configurationEnvelope.providerID == Self.providerID,
              configurationEnvelope.payloadVersion == Self.configurationVersion
        else {
            throw PersistentTerminalError.invalidConfiguration
        }
        do {
            let configuration = try JSONDecoder().decode(
                TmuxProviderConfiguration.self,
                from: configurationEnvelope.providerPayload
            )
            guard configurationEnvelope.configurationKey == configuration.locator.configurationKey else {
                throw PersistentTerminalError.invalidConfiguration
            }
            return configuration
        } catch let issue as PersistentTerminalError {
            throw issue
        } catch {
            throw PersistentTerminalError.invalidConfiguration
        }
    }

    private func resolveRuntime(
        configuration: TmuxProviderConfiguration,
        in context: PersistentTerminalContext
    ) async throws -> TmuxStaticRuntime {
        let cacheKey = TmuxStaticRuntimeCacheKey(context: context)
        if let cached = await Self.staticRuntimeCache.value(for: cacheKey) {
            return cached
        }
        let resolved = try await resolveRuntimeUncached(
            configuration: configuration,
            in: context
        )
        await Self.staticRuntimeCache.insert(
            resolved,
            session: context.session,
            for: cacheKey
        )
        return resolved
    }

    private func resolveRuntimeUncached(
        configuration: TmuxProviderConfiguration,
        in context: PersistentTerminalContext
    ) async throws -> TmuxStaticRuntime {
        let shell = try await context.session.exec("command -v sh")
        guard shell.isSuccess else {
            throw PersistentTerminalError.executableMissing
        }
        let shellPath = try decodeExecutablePath(shell.stdout)
        let scriptProvider = POSIXScriptExecutionProvider()
        let runtime: PreparedRemoteScriptRuntime
        do {
            runtime = try scriptProvider.prepareRuntime(
                resolvedExecutablePath: shellPath,
                interpreter: .sh
            )
        } catch {
            throw PersistentTerminalError.invalidConfiguration
        }

        let tmuxPrefix = (["\"$tmux_path\""] + configuration.locator.arguments.map(
            POSIXShellArgument.encode
        )).joined(separator: " ")
        let staticProbe = """
        set -u
        tmux_path=$(command -v tmux) || exit 72
        case "$tmux_path" in /*) ;; *) exit 73 ;; esac
        printf '__CONN_TMUX_EXECUTABLE__%s\\n' "$tmux_path"
        if tmux_version=$(\(tmuxPrefix) -V); then
            printf '__CONN_TMUX_VERSION__%s\\n' "$tmux_version"
        else
            exit 74
        fi
        \(tmuxPrefix) list-commands >/dev/null || exit 75
        """
        let staticResult = try await execute(
            script: staticProbe,
            runtime: runtime,
            in: context
        )
        guard staticResult.isSuccess else {
            switch staticResult.exitCode {
            case 72, 127:
                throw PersistentTerminalError.executableMissing
            case 73:
                throw PersistentTerminalError.invalidConfiguration
            case 74:
                throw PersistentTerminalError.incompatibleVersion(staticResult.stderrText)
            default:
                throw commandRejected(staticResult)
            }
        }

        let executable: TmuxExecutablePath
        let version: String
        do {
            (executable, version) = try decodeStaticRuntimeProbe(staticResult.stdout)
        } catch {
            throw PersistentTerminalError.invalidConfiguration
        }
        guard !version.isEmpty else {
            throw PersistentTerminalError.incompatibleVersion(nil)
        }
        return TmuxStaticRuntime(
            configuration: configuration,
            runtime: runtime,
            executable: executable,
            version: version
        )
    }

    private func decodeStaticRuntimeProbe(
        _ data: Data
    ) throws -> (TmuxExecutablePath, String) {
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw TmuxProviderError.malformedProbeOutput
        }
        var lines = text.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        let executableMarker = "__CONN_TMUX_EXECUTABLE__"
        let versionMarker = "__CONN_TMUX_VERSION__"
        guard lines.count == 2,
              lines[0].hasPrefix(executableMarker),
              lines[1].hasPrefix(versionMarker)
        else {
            throw TmuxProviderError.malformedProbeOutput
        }
        let executable = try TmuxExecutablePath(String(lines[0].dropFirst(executableMarker.count)))
        let rawVersion = String(lines[1].dropFirst(versionMarker.count))
        let version = decodeVersion(Data(rawVersion.utf8))
        guard !version.isEmpty else { throw TmuxProviderError.malformedProbeOutput }
        return (executable, version)
    }

    private func readQuotedWorkspaceCatalog(
        using runtime: TmuxStaticRuntime,
        in context: PersistentTerminalContext
    ) async throws -> TmuxWorkspaceCatalogObservation? {
        // Identity and sessions come from one tmux command queue. Besides saving an
        // SSH round trip, this cannot combine an old server identity with a restarted
        // server's session list.
        let identityFormat = "\"I\" \"#{q:socket_path}\" \"#{pid}\" \"#{start_time}\""
        let sessionFormat = "\"S\" \"#{q:session_id}\" \"#{q:session_name}\" \"\""
        let result = try await execute(
            script: tmuxScript(
                executable: runtime.executable,
                locator: runtime.configuration.locator,
                arguments: [
                    "display-message", "-p", identityFormat,
                    ";",
                    "list-sessions", "-F", sessionFormat,
                ]
            ),
            runtime: runtime.runtime,
            in: context
        )
        guard result.isSuccess else {
            if isServerAbsent(result.stderrText) { return nil }
            throw commandRejected(result)
        }

        var output = result.stdout
        if output.last == UInt8(ascii: "\n") {
            output.removeLast()
            if output.last == UInt8(ascii: "\r") { output.removeLast() }
        }
        guard !output.isEmpty else { throw TmuxProviderError.malformedProbeOutput }
        let records = try TmuxQuotedSnapshotCodec().decode(
            commandOutputLines: [output],
            expectedFieldCount: 4
        )
        guard let identity = records.first,
              identity[0] == "I",
              let pid = Int32(identity[2]),
              let startTime = Int64(identity[3])
        else {
            throw TmuxProviderError.malformedProbeOutput
        }
        let token: TmuxServerInstanceToken
        do {
            token = try TmuxServerInstanceToken(
                resolvedSocketPath: identity[1],
                serverPID: pid,
                serverStartTime: startTime
            )
        } catch {
            throw TmuxProviderError.malformedProbeOutput
        }

        var sessions: [TmuxWorkspaceCatalogObservation.Session] = []
        sessions.reserveCapacity(max(records.count - 1, 0))
        for record in records.dropFirst() {
            guard record[0] == "S", record[3].isEmpty else {
                throw TmuxProviderError.malformedProbeOutput
            }
            sessions.append(.init(
                id: try decodeSessionID(record[1]),
                name: record[2]
            ))
        }
        return TmuxWorkspaceCatalogObservation(token: token, sessions: sessions)
    }

    private func readLegacyWorkspaceCatalog(
        using runtime: TmuxStaticRuntime,
        in context: PersistentTerminalContext
    ) async throws -> TmuxWorkspaceCatalogObservation? {
        guard let token = try await readServerIdentity(using: runtime, in: context) else {
            return nil
        }
        let list = try await execute(
            script: tmuxScript(
                executable: runtime.executable,
                locator: runtime.configuration.locator,
                arguments: ["list-sessions", "-F", "#{session_id}"]
            ),
            runtime: runtime.runtime,
            in: context
        )
        guard list.isSuccess else { throw commandRejected(list) }
        let sessionIDs = try decodeSessionIDs(list.stdout)
        var sessions: [TmuxWorkspaceCatalogObservation.Session] = []
        sessions.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            let nameResult = try await execute(
                script: tmuxScript(
                    executable: runtime.executable,
                    locator: runtime.configuration.locator,
                    arguments: [
                        "display-message", "-p", "-t", sessionID.rawValue, "#{session_name}",
                    ]
                ),
                runtime: runtime.runtime,
                in: context
            )
            guard nameResult.isSuccess else { throw commandRejected(nameResult) }
            sessions.append(.init(
                id: sessionID,
                name: try decodeSingleTextField(nameResult.stdout)
            ))
        }
        return TmuxWorkspaceCatalogObservation(token: token, sessions: sessions)
    }

    private func readServerIdentity(
        using runtime: TmuxStaticRuntime,
        in context: PersistentTerminalContext
    ) async throws -> TmuxServerInstanceToken? {
        // Read all identity fields in one tmux command. Three separate display-message
        // calls can observe two different server generations during a restart and create
        // a token that never existed.
        let result = try await execute(
            script: tmuxScript(
                executable: runtime.executable,
                locator: runtime.configuration.locator,
                arguments: [
                    "display-message", "-p", "#{socket_path}\n#{pid}\n#{start_time}",
                ]
            ),
            runtime: runtime.runtime,
            in: context
        )
        guard result.isSuccess else {
            if isServerAbsent(result.stderrText) { return nil }
            throw commandRejected(result)
        }

        var lines = String(decoding: result.stdout, as: UTF8.self)
            .components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 3,
              let pid = Int32(lines[1]),
              let start = Int64(lines[2]),
              !lines[0].isEmpty
        else {
            throw TmuxProviderError.malformedProbeOutput
        }
        do {
            return try TmuxServerInstanceToken(
                resolvedSocketPath: lines[0],
                serverPID: pid,
                serverStartTime: start
            )
        } catch {
            throw TmuxProviderError.malformedProbeOutput
        }
    }

    private func execute(
        script: String,
        runtime: PreparedRemoteScriptRuntime,
        in context: PersistentTerminalContext
    ) async throws -> ExecResult {
        try await context.session.exec(
            try runtime.invocation(for: script),
            timeout: .seconds(30)
        )
    }

    private func tmuxScript(
        executable: TmuxExecutablePath,
        locator: TmuxServerLocator,
        arguments: [String]
    ) -> String {
        (["exec", executable.value] + locator.arguments + arguments)
            .map(POSIXShellArgument.encode)
            .joined(separator: " ")
    }

    private func decodeExecutablePath(_ data: Data) throws -> String {
        let value = try decodeSingleTextField(data)
        guard value.hasPrefix("/") else { throw TmuxProviderError.malformedProbeOutput }
        return value
    }

    private func decodeSingleTextField(_ data: Data) throws -> String {
        var bytes = data
        if bytes.last == UInt8(ascii: "\n") {
            bytes.removeLast()
            if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
        }
        guard let value = String(data: bytes, encoding: .utf8),
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw TmuxProviderError.malformedProbeOutput
        }
        return value
    }

    private func decodeVersion(_ data: Data) -> String {
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("tmux ") ? String(value.dropFirst(5)) : value
    }

    private func decodeSessionIDs(_ data: Data) throws -> [TmuxSessionID] {
        let text = String(decoding: data, as: UTF8.self)
        return try text.split(whereSeparator: \.isNewline).map { try decodeSessionID(String($0)) }
    }

    private func decodeSessionID(_ value: String) throws -> TmuxSessionID {
        guard let sessionID = TmuxSessionID(rawValue: value) else {
            throw TmuxProviderError.malformedProbeOutput
        }
        return sessionID
    }

    private func decodeCreatedWorkspace(_ data: Data) throws -> CreatedWorkspace {
        var bytes = data
        if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
        if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
        let fields = bytes.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false)
        guard fields.count == 2,
              let sessionIDText = String(data: Data(fields[0]), encoding: .utf8),
              let name = String(data: Data(fields[1]), encoding: .utf8),
              !name.isEmpty,
              !name.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw TmuxProviderError.malformedProbeOutput
        }
        return CreatedWorkspace(
            sessionID: try decodeSessionID(sessionIDText),
            name: name
        )
    }

    private func makeProviderInstance(
        token: TmuxServerInstanceToken
    ) throws -> PersistentTerminalProviderInstance {
        let payload = try JSONEncoder().encode(TmuxWorkspaceInstancePayload(serverInstanceToken: token))
        return PersistentTerminalProviderInstance(
            payloadVersion: Self.workspaceInstancePayloadVersion,
            providerPayload: payload
        )
    }

    private func makeCatalogSnapshot(
        token: TmuxServerInstanceToken,
        workspaces: [RemoteWorkspaceSummary],
        configurationKey: String,
        freshness: PersistentWorkspaceCatalogFreshness
    ) throws -> PersistentWorkspaceCatalogSnapshot {
        let observedAt: Date = switch freshness {
        case let .liveSubscription(observedAt), let .snapshot(observedAt): observedAt
        case let .stale(lastObservedAt): lastObservedAt ?? Date()
        case .unavailable: Date()
        }
        return PersistentWorkspaceCatalogSnapshot(
            providerID: Self.providerID,
            configurationKey: configurationKey,
            instance: try makeProviderInstance(token: token),
            workspaces: workspaces,
            freshness: freshness,
            observedAt: observedAt
        )
    }

    private func workspaceRef(
        sessionID: TmuxSessionID,
        token: TmuxServerInstanceToken
    ) throws -> RemoteWorkspaceRef {
        RemoteWorkspaceRef(
            workspaceID: sessionID.rawValue,
            instancePayloadVersion: Self.workspaceInstancePayloadVersion,
            providerInstancePayload: try JSONEncoder().encode(
                TmuxWorkspaceInstancePayload(serverInstanceToken: token)
            )
        )
    }

    private func workspaceSummary(
        sessionID: TmuxSessionID,
        name: String,
        token: TmuxServerInstanceToken
    ) throws -> RemoteWorkspaceSummary {
        RemoteWorkspaceSummary(
            workspace: try workspaceRef(sessionID: sessionID, token: token),
            name: name,
            occupancy: RemoteWorkspaceOccupancy(
                affectedAttachmentCount: nil,
                observedAt: .now,
                freshness: .fresh
            )
        )
    }

    private func decodeToken(from workspace: RemoteWorkspaceRef) throws -> TmuxServerInstanceToken {
        guard workspace.instancePayloadVersion == Self.workspaceInstancePayloadVersion else {
            throw PersistentTerminalError.unsupportedDescriptorVersion(
                providerID: Self.providerID,
                component: .workspaceInstance,
                version: workspace.instancePayloadVersion
            )
        }
        do {
            return try JSONDecoder().decode(
                TmuxWorkspaceInstancePayload.self,
                from: workspace.providerInstancePayload
            ).serverInstanceToken
        } catch {
            throw PersistentTerminalError.invalidConfiguration
        }
    }

    private func makeScope(
        context: PersistentTerminalContext,
        token: TmuxServerInstanceToken
    ) throws -> TmuxOperationScope {
        try TmuxOperationScope(
            connectionIdentity: context.connectionIdentity,
            configurationKey: context.backendConfiguration.configurationKey,
            instanceToken: token,
            generation: 0
        )
    }

    private static func makeNonce() throws -> TmuxInvocationNonce {
        try TmuxInvocationNonce(UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    }

    private func commandRejected(_ result: ExecResult) -> PersistentTerminalError {
        PersistentTerminalError.commandRejected(
            result.stderrText.isEmpty ? "tmux command failed" : result.stderrText
        )
    }

    private func isServerAbsent(_ diagnostic: String) -> Bool {
        let value = diagnostic.lowercased()
        return value.contains("no server running")
            || value.contains("no sessions")
            || value.contains("no such file")
            || value.contains("can't find socket")
    }
}

package protocol TmuxRuntimeAttachmentIdentifying: PersistentTerminalAttachment {
    var runtimeAttachmentID: String { get }
}

private enum TmuxAttachmentStartupTransactionError: Error, Sendable {
    case missingControlPreflight
    case missingProcess
    case missingAttachment
    case missingControlBinding
}

private actor TmuxAttachmentStartupFailureBox {
    private(set) var failure: (any Error)?

    func record(_ error: any Error) {
        if failure == nil { failure = error }
    }
}

/// Provider-owned mutable state captured by generic startup steps. Every take/rollback
/// operation is idempotent so cancellation and a concurrently closing tab cannot leak a
/// partially assembled Control Mode or PTY process.
private actor TmuxAttachmentStartupTransaction {
    private var controlLease: TmuxProviderControlRuntimeLease?
    private var remoteProcess: (any RemoteProcessChannel)?
    private var openedAttachment: TmuxPassthroughAttachment?
    private var isControlBound = false

    func storeControlPreflight(_ lease: TmuxProviderControlRuntimeLease) {
        controlLease = lease
    }

    func controlPreflight() throws -> TmuxProviderControlRuntimeLease {
        guard let controlLease else {
            throw TmuxAttachmentStartupTransactionError.missingControlPreflight
        }
        return controlLease
    }

    func consumeControlPreflight() throws -> TmuxProviderControlRuntimeLease {
        let lease = try controlPreflight()
        controlLease = nil
        return lease
    }

    func rollbackControlPreflight() async {
        guard let lease = controlLease else { return }
        controlLease = nil
        await lease.registry.releasePreflight(lease)
    }

    func storeProcess(_ process: any RemoteProcessChannel) {
        remoteProcess = process
    }

    func process() throws -> any RemoteProcessChannel {
        guard let remoteProcess else {
            throw TmuxAttachmentStartupTransactionError.missingProcess
        }
        return remoteProcess
    }

    func rollbackProcess() async {
        guard let process = remoteProcess else { return }
        remoteProcess = nil
        await process.close()
    }

    func storeAttachment(_ attachment: TmuxPassthroughAttachment) {
        openedAttachment = attachment
    }

    func attachment() throws -> TmuxPassthroughAttachment {
        guard let openedAttachment else {
            throw TmuxAttachmentStartupTransactionError.missingAttachment
        }
        return openedAttachment
    }

    func rollbackAttachment() async {
        guard let attachment = openedAttachment else { return }
        openedAttachment = nil
        isControlBound = false
        await attachment.close()
    }

    func markControlBound() {
        isControlBound = true
    }

    func validateReady() throws {
        guard openedAttachment != nil else {
            throw TmuxAttachmentStartupTransactionError.missingAttachment
        }
        guard isControlBound else {
            throw TmuxAttachmentStartupTransactionError.missingControlBinding
        }
    }

    func finishedAttachment() throws -> TmuxPassthroughAttachment {
        try validateReady()
        return try attachment()
    }
}

private actor TmuxAttachmentGenerationSource {
    private var generation: UInt64 = 0

    func next() -> UInt64 {
        generation &+= 1
        return generation
    }
}

package final class TmuxPassthroughAttachment:
    TmuxRuntimeAttachmentIdentifying,
    PersistentTerminalInteractiveAttachment,
    @unchecked Sendable
{
    private static let controlComponentID: PersistentTerminalRuntimeComponentID =
        "tmux.control-mode"

    package let descriptor: PersistentAttachmentDescriptor
    package let presentation: PersistentAttachmentPresentation
    package let lifecycleEvents: AsyncStream<PersistentTerminalAttachmentLifecycleEvent>
    package let runtimeAttachmentID: String
    package let attachmentGeneration: UInt64
    package var interaction: any PersistentTerminalInteractionFacet { interactionFacet }
    private let channel: TmuxProcessShellChannel
    private let interactionFacet: TmuxInteractionFacet
    private let lifecycleContinuation:
        AsyncStream<PersistentTerminalAttachmentLifecycleEvent>.Continuation
    private let lifecycleLock = NSLock()
    private var didClose = false
    private var controlLifecycleTask: Task<Void, Never>?

    private init(
        descriptor: PersistentAttachmentDescriptor,
        channel: TmuxProcessShellChannel,
        runtimeAttachmentID: String,
        attachmentGeneration: UInt64,
        interactionFacet: TmuxInteractionFacet
    ) {
        self.descriptor = descriptor
        self.channel = channel
        self.runtimeAttachmentID = runtimeAttachmentID
        self.attachmentGeneration = attachmentGeneration
        self.interactionFacet = interactionFacet
        presentation = .byteTerminal(channel)
        let lifecycle = AsyncStream.makeStream(
            of: PersistentTerminalAttachmentLifecycleEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        lifecycleEvents = lifecycle.stream
        lifecycleContinuation = lifecycle.continuation
    }

    static func open(
        descriptor: PersistentAttachmentDescriptor,
        process: any RemoteProcessChannel,
        nonce: TmuxInvocationNonce,
        runtimeAttachmentID: String,
        attachmentGeneration: UInt64,
        interactionFactory: @Sendable (String, Int32) -> TmuxInteractionFacet
    ) async throws -> TmuxPassthroughAttachment {
        let channel = TmuxProcessShellChannel(process: process, nonce: nonce)
        do {
            try await channel.waitForReadiness()
            let identity = channel.processIdentity
            return TmuxPassthroughAttachment(
                descriptor: descriptor,
                channel: channel,
                runtimeAttachmentID: runtimeAttachmentID,
                attachmentGeneration: attachmentGeneration,
                interactionFacet: interactionFactory(
                    identity?.tty ?? "",
                    identity?.pid ?? -1
                )
            )
        } catch {
            await channel.close()
            throw error
        }
    }

    fileprivate var processIdentity: (tty: String, pid: Int32)? {
        channel.processIdentity
    }

    func installControlLease(_ controlLease: TmuxProviderControlInteractionLease) async {
        guard lifecycleLock.withLock({ !didClose }) else {
            await controlLease.registry.release(controlLease)
            return
        }
        await interactionFacet.install(controlLease)
        let terminations = controlLease.runtime.terminationEvents()
        controlLifecycleTask = Task { [weak self] in
            for await reason in terminations {
                guard !Task.isCancelled else { return }
                await self?.controlModeTerminated(reason)
                return
            }
        }
    }

    package func close() async {
        let shouldClose = lifecycleLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }
        controlLifecycleTask?.cancel()
        controlLifecycleTask = nil
        await interactionFacet.close()
        await channel.close()
        lifecycleContinuation.finish()
    }

    private func controlModeTerminated(_ reason: TmuxControlClientTermination) async {
        let shouldInvalidate = lifecycleLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldInvalidate else { return }

        let issue: PersistentTerminalError
        let recovery: PersistentTerminalAttachmentRecovery
        switch reason {
        case .protocolViolation:
            issue = .protocolViolation
            recovery = .manual
        case .remoteExit:
            issue = .remoteObjectMissing
            recovery = .manual
        case .transportFailure, .requested:
            issue = .transportClosed
            recovery = .rebuildAttachment
        }
        lifecycleContinuation.yield(.failed(.init(
            componentID: Self.controlComponentID,
            issue: issue,
            recovery: recovery
        )))
        lifecycleContinuation.finish()
        await interactionFacet.close()
        await channel.close()
    }
}

public final class TmuxWorkspaceCatalogAttachment: TmuxWorkspaceCatalogManaging, @unchecked Sendable {
    public let snapshots: AsyncStream<PersistentWorkspaceCatalogSnapshot>
    private let continuation: AsyncStream<PersistentWorkspaceCatalogSnapshot>.Continuation
    public let topology: AsyncStream<TmuxServerSnapshot>
    private let topologyContinuation: AsyncStream<TmuxServerSnapshot>.Continuation
    public let controlCapabilities: TmuxNegotiatedCapabilities
    public let controlConfiguration: TmuxControlClientConfiguration
    private let lease: TmuxProviderControlCatalogLease
    private let task: Task<Void, Never>
    private let lock = NSLock()
    private var didClose = false

    init(
        providerID: String,
        configurationKey: String,
        instanceToken: TmuxServerInstanceToken,
        lease: TmuxProviderControlCatalogLease,
        controlCapabilities: TmuxNegotiatedCapabilities,
        controlConfiguration: TmuxControlClientConfiguration
    ) {
        let (snapshots, continuation) = PersistentTerminalCatalogStreams.makeStateStream(
            of: PersistentWorkspaceCatalogSnapshot.self
        )
        let (topology, topologyContinuation) = PersistentTerminalCatalogStreams.makeStateStream(
            of: TmuxServerSnapshot.self
        )
        self.snapshots = snapshots
        self.continuation = continuation
        self.topology = topology
        self.topologyContinuation = topologyContinuation
        self.controlCapabilities = controlCapabilities
        self.controlConfiguration = controlConfiguration
        self.lease = lease
        let observation = lease.observation.snapshots
        task = Task {
            for await snapshot in observation {
                topologyContinuation.yield(snapshot)
                continuation.yield(Self.makeCatalogSnapshot(
                    providerID: providerID,
                    configurationKey: configurationKey,
                    instanceToken: instanceToken,
                    snapshot: snapshot
                ))
            }
            continuation.finish()
            topologyContinuation.finish()
        }
    }

    public func execute(_ operation: TmuxOperation) async throws {
        let request = TmuxOperationRequest(scope: lease.scope, operation: operation)
        _ = try await lease.hub.execute(request, timeout: .seconds(30))
    }

    public func previewImpact(_ operation: TmuxOperation) async throws -> TmuxOperationImpact {
        try await lease.hub.previewImpact(
            TmuxOperationRequest(scope: lease.scope, operation: operation)
        )
    }

    public func prepareDestructive(
        _ operation: TmuxOperation
    ) async throws -> TmuxPreparedDestructiveOperation {
        try await lease.hub.prepareDestructive(
            TmuxOperationRequest(scope: lease.scope, operation: operation)
        )
    }

    public func executeDestructive(
        _ prepared: TmuxPreparedDestructiveOperation
    ) async throws {
        _ = try await lease.hub.executeDestructive(
            prepared.claim,
            for: prepared.request,
            timeout: .seconds(30)
        )
    }

    public func close() async {
        let shouldClose = lock.withLock {
            guard !didClose else { return false }
            didClose = true
            continuation.finish()
            topologyContinuation.finish()
            return true
        }
        guard shouldClose else { return }
        task.cancel()
        await lease.registry.releaseCatalog(lease)
    }

    private static func makeCatalogSnapshot(
        providerID: String,
        configurationKey: String,
        instanceToken: TmuxServerInstanceToken,
        snapshot: TmuxServerSnapshot
    ) -> PersistentWorkspaceCatalogSnapshot {
        let payload = (try? JSONEncoder().encode(
            TmuxWorkspaceInstancePayload(serverInstanceToken: instanceToken)
        )) ?? Data()
        let instance = PersistentTerminalProviderInstance(
            payloadVersion: TmuxProvider.workspaceInstancePayloadVersion,
            providerPayload: payload
        )
        let workspaces = snapshot.sessions.values
            .sorted { lhs, rhs in
                lhs.name == rhs.name ? lhs.id.rawValue < rhs.id.rawValue : lhs.name < rhs.name
            }
            .map { session in
                RemoteWorkspaceSummary(
                    workspace: RemoteWorkspaceRef(
                        workspaceID: session.id.rawValue,
                        instancePayloadVersion: TmuxProvider.workspaceInstancePayloadVersion,
                        providerInstancePayload: payload
                    ),
                    name: session.name,
                    occupancy: RemoteWorkspaceOccupancy(
                        affectedAttachmentCount: snapshot.affectedAttachedClientCount(in: session.id),
                        observedAt: snapshot.observedAt,
                        freshness: .fresh
                    ),
                    status: snapshot.sessionGroups.first(where: { $0.value.contains(session.id) })?.key
                )
            }
        return PersistentWorkspaceCatalogSnapshot(
            providerID: providerID,
            configurationKey: configurationKey,
            instance: instance,
            workspaces: workspaces,
            freshness: .liveSubscription(observedAt: snapshot.observedAt),
            observedAt: snapshot.observedAt
        )
    }
}

private final class TmuxStaticCatalogAttachment: PersistentTerminalCatalogAttachment, @unchecked Sendable {
    let snapshots: AsyncStream<PersistentWorkspaceCatalogSnapshot>
    private let continuation: AsyncStream<PersistentWorkspaceCatalogSnapshot>.Continuation
    private let lock = NSLock()
    private var didClose = false

    init(snapshot: PersistentWorkspaceCatalogSnapshot) {
        let (snapshots, continuation) = AsyncStream<PersistentWorkspaceCatalogSnapshot>.makeStream()
        self.snapshots = snapshots
        self.continuation = continuation
        continuation.yield(snapshot)
    }

    func close() async {
        lock.withLock {
            guard !didClose else { return }
            didClose = true
            continuation.finish()
        }
    }
}

private final class TmuxProcessShellChannel: ShellChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let process: any RemoteProcessChannel
    private let gate = TmuxAttachmentReadinessGate()
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let nonce: TmuxInvocationNonce
    private let lock = NSLock()
    private var preamble = Data()
    private var preambleScanOffset = 0
    private var didResolveReadiness = false
    private var didClose = false
    private var pumpTask: Task<Void, Never>?
    fileprivate private(set) var processIdentity: (tty: String, pid: Int32)?

    init(process: any RemoteProcessChannel, nonce: TmuxInvocationNonce) {
        self.process = process
        self.nonce = nonce
        (output, outputContinuation) = AsyncThrowingStream.makeStream()
        outputContinuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.close() }
        }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    func waitForReadiness() async throws {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.gate.fail(TmuxProviderError.attachmentHandshakeFailed)
        }
        defer { timeout.cancel() }
        guard let identity = try await gate.waitForReady() else {
            throw TmuxProviderError.attachmentHandshakeFailed
        }
        processIdentity = identity
    }

    func write(_ bytes: Data) async throws {
        try await process.write(bytes)
    }

    func resize(_ size: TermSize) async throws {
        try await process.resize(size)
    }

    func close() async {
        guard lock.withLock({
            guard !didClose else { return false }
            didClose = true
            return true
        }) else { return }
        gate.terminate()
        await process.close()
        pumpTask?.cancel()
        if let pumpTask { await pumpTask.value }
        outputContinuation.finish()
    }

    private func pump() async {
        do {
            for try await event in process.output {
                if Task.isCancelled { return }
                let data: Data
                switch event {
                case let .stdout(value), let .stderr(value):
                    data = value
                }
                consume(data)
            }
            if !lock.withLock({ didResolveReadiness }) {
                gate.fail(TmuxProviderError.attachmentHandshakeFailed)
                outputContinuation.finish(throwing: TmuxProviderError.attachmentHandshakeFailed)
            } else {
                outputContinuation.finish()
            }
        } catch {
            if !lock.withLock({ didResolveReadiness }) {
                gate.fail(error)
            }
            outputContinuation.finish(throwing: error)
        }
    }

    private func consume(_ data: Data) {
        if lock.withLock({ didResolveReadiness }) {
            outputContinuation.yield(data)
            return
        }

        var bufferedOutput: Data?
        var identity: (tty: String, pid: Int32)?
        var readinessFailure: TmuxProviderError?
        lock.lock()
        if didResolveReadiness {
            lock.unlock()
            outputContinuation.yield(data)
            return
        }

        preamble.append(data)
        if preamble.count > 4 * 1_024 {
            preamble.removeAll(keepingCapacity: true)
            preambleScanOffset = 0
            readinessFailure = .attachmentHandshakeFailed
        } else {
            while preambleScanOffset < preamble.count,
                  let newline = preamble[preambleScanOffset...]
                    .firstIndex(of: UInt8(ascii: "\n")) {
                var line = Data(preamble[preambleScanOffset..<newline])
                preambleScanOffset = newline + 1
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                if let parsed = parseHandshake(line) {
                    didResolveReadiness = true
                    identity = parsed
                    let afterHandshake = newline + 1
                    if afterHandshake < preamble.count {
                        bufferedOutput = Data(preamble[afterHandshake...])
                    }
                    preamble.removeAll(keepingCapacity: true)
                    preambleScanOffset = 0
                    break
                }
            }
        }
        lock.unlock()

        if let identity {
            gate.ready(identity)
        } else if let readinessFailure {
            gate.fail(readinessFailure)
            outputContinuation.finish(throwing: readinessFailure)
            return
        }
        if let bufferedOutput, !bufferedOutput.isEmpty {
            outputContinuation.yield(bufferedOutput)
        }
    }

    private func parseHandshake(_ line: Data) -> (tty: String, pid: Int32)? {
        let text = String(decoding: line, as: UTF8.self)
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count == 4,
              fields[0] == "__CONN_TMUX_ATTACH_v1__",
              fields[1] == "nonce=\(nonce.value)",
              fields[2].hasPrefix("tty="),
              fields[3].hasPrefix("pid="),
              let pid = Int32(fields[3].dropFirst(4)),
              pid > 0
        else { return nil }
        let tty = String(fields[2].dropFirst(4))
        guard !tty.isEmpty,
              !tty.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        return (tty, pid)
    }

}

/// Consumes and validates the provider-owned Control Mode handshake before exposing the
/// channel to `TmuxControlClient`. The protocol parser must never be asked to interpret
/// arbitrary shell/banner output; only bytes after this frame belong to tmux Control Mode.
private final class TmuxControlHandshakeChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>

    private let process: any RemoteProcessChannel
    private let nonce: String
    private let gate = TmuxAttachmentReadinessGate()
    private let outputContinuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let lock = NSLock()
    private var preamble = Data()
    private var didResolveReadiness = false
    private var didClose = false
    private var pumpTask: Task<Void, Never>?
    fileprivate private(set) var processIdentity: (tty: String, pid: Int32) = ("", 0)

    private init(process: any RemoteProcessChannel, nonce: String) {
        self.process = process
        self.nonce = nonce
        (output, outputContinuation) = AsyncThrowingStream.makeStream()
        outputContinuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.close() }
        }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    static func open(
        process: any RemoteProcessChannel,
        nonce: String
    ) async throws -> TmuxControlHandshakeChannel {
        let channel = TmuxControlHandshakeChannel(process: process, nonce: nonce)
        do {
            channel.processIdentity = try await channel.waitForReadiness()
            return channel
        } catch {
            await channel.close()
            throw error
        }
    }

    func write(_ data: Data) async throws {
        try await process.write(data)
    }

    func resize(_ size: TermSize) async throws {
        try await process.resize(size)
    }

    func result() async throws -> RemoteProcessExit {
        try await process.result()
    }

    func close() async {
        guard lock.withLock({
            guard !didClose else { return false }
            didClose = true
            return true
        }) else { return }
        gate.terminate()
        await process.close()
        pumpTask?.cancel()
        if let pumpTask { await pumpTask.value }
        outputContinuation.finish()
    }

    private func waitForReadiness() async throws -> (tty: String, pid: Int32) {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            gate.fail(TmuxProviderError.attachmentHandshakeFailed)
        }
        defer { timeout.cancel() }
        guard let identity = try await gate.waitForReady() else {
            throw TmuxProviderError.attachmentHandshakeFailed
        }
        return identity
    }

    private func pump() async {
        do {
            for try await event in process.output {
                if Task.isCancelled { return }
                switch event {
                case let .stdout(data): consumeStdout(data)
                case let .stderr(data): outputContinuation.yield(.stderr(data))
                }
            }
            if lock.withLock({ didResolveReadiness }) {
                outputContinuation.finish()
            } else {
                gate.fail(TmuxProviderError.attachmentHandshakeFailed)
                outputContinuation.finish(throwing: TmuxProviderError.attachmentHandshakeFailed)
            }
        } catch {
            if !lock.withLock({ didResolveReadiness }) {
                gate.fail(error)
            }
            outputContinuation.finish(throwing: error)
        }
    }

    private func consumeStdout(_ data: Data) {
        if lock.withLock({ didResolveReadiness }) {
            outputContinuation.yield(.stdout(data))
            return
        }

        var bufferedOutput: Data?
        var handshake: (tty: String, pid: Int32)?
        lock.lock()
        if didResolveReadiness {
            lock.unlock()
            outputContinuation.yield(.stdout(data))
            return
        }

        preamble.append(data)
        guard preamble.count <= 4 * 1_024 else {
            lock.unlock()
            gate.fail(TmuxProviderError.attachmentHandshakeFailed)
            return
        }

        while let newline = preamble.firstIndex(of: UInt8(ascii: "\n")) {
            var line = Data(preamble[..<newline])
            preamble.removeFirst(preamble.distance(from: preamble.startIndex, to: newline) + 1)
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            guard let parsed = parseHandshake(line) else { continue }
            didResolveReadiness = true
            handshake = parsed
            if !preamble.isEmpty {
                bufferedOutput = preamble
                preamble.removeAll(keepingCapacity: true)
            }
            break
        }
        lock.unlock()

        guard let handshake else { return }
        gate.ready(handshake)
        if let bufferedOutput, !bufferedOutput.isEmpty {
            outputContinuation.yield(.stdout(bufferedOutput))
        }
    }

    private func parseHandshake(_ line: Data) -> (tty: String, pid: Int32)? {
        let fields = String(decoding: line, as: UTF8.self)
            .split(separator: " ")
            .map(String.init)
        guard fields.count == 4,
              fields[0] == "__CONN_TMUX_CONTROL_v1__",
              fields[1] == "nonce=\(nonce)",
              fields[2].hasPrefix("tty="),
              fields[3].hasPrefix("pid=")
        else { return nil }
        let tty = String(fields[2].dropFirst(4))
        let pid = Int32(fields[3].dropFirst(4)) ?? 0
        guard !tty.isEmpty, pid > 0 else { return nil }
        return (tty, pid)
    }
}

private final class TmuxAttachmentReadinessGate: @unchecked Sendable {
    private enum State {
        case pending
        case ready((tty: String, pid: Int32)?)
        case failed(any Error)
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var waiter: CheckedContinuation<(tty: String, pid: Int32)?, Error>?

    func waitForReady() async throws -> (tty: String, pid: Int32)? {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<(tty: String, pid: Int32)?, Error>? = lock.withLock {
                switch state {
                case .pending:
                    waiter = continuation
                    return nil
                case let .ready(identity):
                    return .success(identity)
                case let .failed(error):
                    return .failure(error)
                }
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func ready(_ identity: (tty: String, pid: Int32)?) {
        complete(.ready(identity))
    }

    func fail(_ error: any Error) {
        complete(.failed(error))
    }

    func terminate() {
        lock.withLock {
            if case .pending = state {
                state = .failed(SSHError.channelClosed)
                waiter?.resume(throwing: SSHError.channelClosed)
                waiter = nil
            }
        }
    }

    private func complete(_ next: State) {
        let continuation: CheckedContinuation<(tty: String, pid: Int32)?, Error>? = lock.withLock {
            guard case .pending = state else { return nil }
            state = next
            defer { waiter = nil }
            return waiter
        }
        guard let continuation else { return }
        switch next {
        case let .ready(identity): continuation.resume(returning: identity)
        case let .failed(error): continuation.resume(throwing: error)
        case .pending: break
        }
    }
}
