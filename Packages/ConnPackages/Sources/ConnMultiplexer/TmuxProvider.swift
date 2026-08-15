import ConnKit
import ConnSSH
import Foundation

/// Durable configuration owned by the tmux provider. The generic profile stores its
/// JSON opaquely; only this provider is allowed to interpret the payload.
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

    public let descriptor: PersistentTerminalProviderDescriptor

    public init() {
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

        let configuration = try decodeConfiguration(from: context.backendProfile)
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
        let configuration = try decodeConfiguration(from: context.backendProfile)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        guard let token = try await readServerIdentity(using: runtime, in: context) else {
            return []
        }

        let list = try await execute(
            script: tmuxScript(
                executable: runtime.executable,
                locator: configuration.locator,
                arguments: [
                    "list-sessions", "-F", "#{session_id}",
                ]
            ),
            runtime: runtime.runtime,
            in: context
        )
        guard list.isSuccess else {
            throw commandRejected(list)
        }

        let sessionIDs = try decodeSessionIDs(list.stdout)
        let observedAt = Date()
        let workspacePayload = try JSONEncoder().encode(
            TmuxWorkspaceInstancePayload(serverInstanceToken: token)
        )
        var summaries: [RemoteWorkspaceSummary] = []
        summaries.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            let nameResult = try await execute(
                script: tmuxScript(
                    executable: runtime.executable,
                    locator: configuration.locator,
                    arguments: [
                        "display-message", "-p", "-t", sessionID.rawValue, "#{session_name}",
                    ]
                ),
                runtime: runtime.runtime,
                in: context
            )
            guard nameResult.isSuccess else { throw commandRejected(nameResult) }
            let name = try decodeSingleTextField(nameResult.stdout)
            summaries.append(RemoteWorkspaceSummary(
                workspace: RemoteWorkspaceRef(
                    workspaceID: sessionID.rawValue,
                    instancePayloadVersion: Self.workspaceInstancePayloadVersion,
                    providerInstancePayload: workspacePayload
                ),
                name: name,
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
    ) async throws -> RemoteWorkspaceRef {
        let configuration = try decodeConfiguration(from: context.backendProfile)
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
            let sessionID = try decodeFirstSessionID(result.output)
            return try workspaceRef(sessionID: sessionID, token: token)
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
        return try workspaceRef(sessionID: bootstrap.sessionID, token: bootstrap.token)
    }

    public func renameWorkspace(
        _ workspace: RemoteWorkspaceRef,
        to newName: String,
        in context: PersistentTerminalContext
    ) async throws {
        let name = try TmuxName(newName)
        let configuration = try decodeConfiguration(from: context.backendProfile)
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
        let configuration = try decodeConfiguration(from: context.backendProfile)
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
            profileID: context.backendProfile.id,
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
              descriptor.profileID == context.backendProfile.id,
              descriptor.payloadVersion == Self.attachmentPayloadVersion
        else {
            if descriptor.payloadVersion != Self.attachmentPayloadVersion {
                throw PersistentTerminalError.unsupportedDescriptorVersion(
                    providerID: Self.providerID,
                    component: .attachment,
                    version: descriptor.payloadVersion
                )
            }
            throw PersistentTerminalError.profileUnavailable(descriptor.profileID)
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

        let configuration = try decodeConfiguration(from: context.backendProfile)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        let expectedToken = try decodeToken(from: descriptor.workspace)
        guard try await readServerIdentity(using: runtime, in: context) == expectedToken else {
            throw PersistentTerminalError.serverInstanceChanged
        }
        let sessionID = try decodeSessionID(descriptor.workspace.workspaceID)
        let controlScope = try makeScope(context: context, token: expectedToken)
        // Control Mode is an optional management plane. Establish it before the
        // data client so client flags/dialect failure can degrade without blocking
        // the user-selected pass-through attachment.
        let controlLease = await preflightControlMode(
            sessionID: sessionID,
            runtime: runtime,
            configuration: configuration,
            context: context,
            scope: controlScope,
            terminalSize: terminalSize
        )
        let nonce = try Self.makeNonce()
        let clientFlags: Set<TmuxClientFlag>
        if let controlLease {
            clientFlags = await controlLease.runtime.capabilities.supportedClientFlags.intersection([
                .activePane,
                .ignoreSize,
            ])
        } else {
            clientFlags = []
        }
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
        let attachInvocation = tmuxScript(
            executable: runtime.executable,
            locator: configuration.locator,
            arguments: attachArguments
        )
        let attachScript = tmuxHandshakeScript(
            kind: .attachment,
            nonce: nonce.value,
            invocation: attachInvocation
        )
        let command = try runtime.runtime.invocation(for: attachScript)
        let process: any RemoteProcessChannel
        do {
            process = try await context.session.openProcess(
                RemoteProcessRequest(
                    command: command,
                    terminal: RemoteTerminalRequest(
                        type: "xterm-256color",
                        size: terminalSize
                    )
                )
            )
        } catch {
            if let controlLease {
                await Self.controlRuntimeRegistry.releasePreflight(controlLease)
            }
            throw error
        }
        let attachment: TmuxPassthroughAttachment
        do {
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
            let dialect = dialectCandidate(for: runtime.version)
            attachment = try await TmuxPassthroughAttachment.open(
                descriptor: descriptor,
                process: process,
                nonce: nonce,
                runtimeAttachmentID: runtimeAttachmentID,
                attachmentGeneration: attachmentGeneration,
                interactionFactory: { tty, processID in
                    let fallback = TmuxOneShotInteractionBackend(
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
                        fallback: fallback
                    )
                }
            )
        } catch {
            if let controlLease {
                await Self.controlRuntimeRegistry.releasePreflight(controlLease)
            }
            throw error
        }
        do {
            guard try await readServerIdentity(using: runtime, in: context) == expectedToken else {
                throw PersistentTerminalError.serverInstanceChanged
            }
        } catch {
            await attachment.close()
            if let controlLease {
                await Self.controlRuntimeRegistry.releasePreflight(controlLease)
            }
            throw error
        }
        if let controlLease, let identity = attachment.processIdentity {
            let controlAttachmentLease = await Self.controlRuntimeRegistry.acquireAttachment(
                controlLease,
                attachmentID: runtimeAttachmentID,
                attachmentGeneration: attachmentGeneration,
                requestedSessionID: sessionID,
                makeHub: { [self] controlRuntime in
                    await makeControlHub(
                        sessionID: sessionID,
                        runtime: runtime,
                        configuration: configuration,
                        context: context,
                        controlRuntime: controlRuntime,
                        scope: controlScope,
                        attachmentIdentity: identity,
                        attachmentID: runtimeAttachmentID
                    )
                },
                resolveIdentity: { [self] runtime in
                    await resolveControlIdentity(
                        sessionID: sessionID,
                        runtime: runtime,
                        scope: controlScope,
                        attachmentIdentity: identity,
                        attachmentID: runtimeAttachmentID
                    )
                }
            )
            if let controlAttachmentLease {
                await attachment.installControlLease(controlAttachmentLease)
            }
        } else if let controlLease {
            await Self.controlRuntimeRegistry.releasePreflight(controlLease)
        }
        return attachment
    }

    public func openCatalog(
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalCatalogAttachment {
        let configuration = try decodeConfiguration(from: context.backendProfile)
        let runtime = try await resolveRuntime(configuration: configuration, in: context)
        guard let token = try await readServerIdentity(using: runtime, in: context) else {
            let observedAt = Date()
            return TmuxStaticCatalogAttachment(
                snapshot: PersistentWorkspaceCatalogSnapshot(
                    providerID: Self.providerID,
                    profileID: context.backendProfile.id,
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
                    profileID: context.backendProfile.id,
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
                    profileID: context.backendProfile.id,
                    freshness: .snapshot(observedAt: Date())
                )
            )
        }
        guard let lease = await Self.controlRuntimeRegistry.acquireCatalog(
            preflight,
            makeHub: { [self] controlRuntime in
                await makeCatalogHub(
                    runtime: runtime,
                    configuration: configuration,
                    context: context,
                    sessionID: sessionID,
                    scope: scope,
                    controlRuntime: controlRuntime
                )
            }
        ) else {
            return TmuxStaticCatalogAttachment(
                snapshot: try makeCatalogSnapshot(
                    token: token,
                    workspaces: workspaces,
                    profileID: context.backendProfile.id,
                    freshness: .snapshot(observedAt: Date())
                )
            )
        }
        let controlCapabilities = await lease.runtime.capabilities
        let controlConfiguration = await lease.runtime.configuration
        return TmuxWorkspaceCatalogAttachment(
            providerID: Self.providerID,
            profileID: context.backendProfile.id,
            instanceToken: token,
            lease: lease,
            controlCapabilities: controlCapabilities,
            controlConfiguration: controlConfiguration
        )
    }

    /// Completes the optional management-plane handshake after the data client has a
    /// verified tty/PID. If any snapshot or ownership proof is unavailable, the caller
    /// keeps the byte attachment and closes only this optional control runtime.
    private func makeControlHub(
        sessionID: TmuxSessionID,
        runtime: TmuxStaticRuntime,
        configuration: TmuxProviderConfiguration,
        context: PersistentTerminalContext,
        controlRuntime: TmuxControlRuntime,
        scope: TmuxOperationScope,
        attachmentIdentity: (tty: String, pid: Int32),
        attachmentID: String
    ) async -> TmuxProviderControlSetup? {
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
            })?.id,
            let dataClient = firstSnapshot.clients.values.first(where: {
                $0.tty == attachmentIdentity.tty
                    && $0.id.processID == attachmentIdentity.pid
                    && $0.sessionID == sessionID
                    && $0.kind == .interactiveTerminal
            })?.id
            else { return nil }

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
            let oneShot = TmuxOneShotOperationExecutor(
                session: context.session,
                runtime: runtime.runtime,
                executable: runtime.executable,
                locator: configuration.locator,
                scope: scope,
                nonceFactory: { try Self.makeNonce() }
            )
            let adapter = TmuxControlHubRuntimeAdapter(
                initialScope: scope,
                controlClients: controlRuntime,
                oneShot: oneShot,
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
            return TmuxProviderControlSetup(hub: hub, identity: identity)
        } catch {
            return nil
        }
    }

    private func makeCatalogHub(
        runtime: TmuxStaticRuntime,
        configuration: TmuxProviderConfiguration,
        context: PersistentTerminalContext,
        sessionID: TmuxSessionID,
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
            let oneShot = TmuxOneShotOperationExecutor(
                session: context.session,
                runtime: runtime.runtime,
                executable: runtime.executable,
                locator: configuration.locator,
                scope: scope,
                nonceFactory: { try Self.makeNonce() }
            )
            let adapter = TmuxControlHubRuntimeAdapter(
                initialScope: scope,
                controlClients: controlRuntime,
                oneShot: oneShot,
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
    ) async -> TmuxControlInteractiveIdentity? {
        do {
            let snapshot = try await runtime.loadSnapshot(
                scope: scope,
                reason: .userRequested,
                identities: []
            )
            guard let client = snapshot.clients.values.first(where: {
                $0.tty == attachmentIdentity.tty
                    && $0.id.processID == attachmentIdentity.pid
                    && $0.sessionID == sessionID
                    && $0.kind == .interactiveTerminal
            }) else {
                return nil
            }
            let identity = TmuxControlInteractiveIdentity(
                attachmentID: attachmentID,
                clientID: client.id,
                requestedSessionID: sessionID
            )
            _ = try await runtime.loadSnapshot(
                scope: scope,
                reason: .userRequested,
                identities: [identity]
            )
            return identity
        } catch {
            return nil
        }
    }

    private func preflightControlMode(
        sessionID: TmuxSessionID,
        runtime: TmuxStaticRuntime,
        configuration: TmuxProviderConfiguration,
        context: PersistentTerminalContext,
        scope: TmuxOperationScope,
        terminalSize: TermSize
    ) async -> TmuxProviderControlRuntimeLease? {
        let controlRuntime = await Self.controlRuntimeRegistry.acquireRuntime(for: scope) {
            await openControlRuntime(
                sessionID: sessionID,
                runtime: runtime,
                configuration: configuration,
                context: context,
                scope: scope,
                terminalSize: terminalSize
            )
        }
        return controlRuntime
    }

    private func openControlRuntime(
        sessionID: TmuxSessionID,
        runtime: TmuxStaticRuntime,
        configuration: TmuxProviderConfiguration,
        context: PersistentTerminalContext,
        scope: TmuxOperationScope,
        terminalSize: TermSize
    ) async -> TmuxControlRuntime? {
        let controlScript = tmuxScript(
            executable: runtime.executable,
            locator: configuration.locator,
            arguments: ["-CC", "attach-session", "-t", sessionID.rawValue]
        )
        let controlNonce = (try? Self.makeNonce())?.value ?? UUID().uuidString
        let controlWrapper = tmuxHandshakeScript(
            kind: .control,
            nonce: controlNonce,
            invocation: controlScript
        )
        guard let command = try? runtime.runtime.invocation(for: controlWrapper),
              let channel = try? await context.session.openProcess(
                  RemoteProcessRequest(
                      command: command,
                      terminal: RemoteTerminalRequest(type: "xterm-256color", size: terminalSize)
                  )
              )
        else { return nil }

        do {
            let controlChannel = try await TmuxControlHandshakeChannel.open(
                process: channel,
                nonce: controlNonce
            )
            let control = try TmuxControlRuntime(
                channel: controlChannel,
                scope: scope,
                dialect: dialectCandidate(for: runtime.version),
                processIdentity: .init(
                    tty: controlChannel.processIdentity.tty,
                    processID: controlChannel.processIdentity.pid
                )
            )
            try await control.start(timeout: .seconds(5))
            return control
        } catch {
            await channel.close()
            return nil
        }
    }

    /// Version only chooses a conservative parser candidate. Readiness still comes
    /// from the actual Control Mode marker; capability flags are not advertised by
    /// this preflight until a future attach runtime completes negotiation.
    private func dialectCandidate(for version: String) -> TmuxProtocolDialect {
        let numbers = version.split(separator: ".").compactMap { Int($0) }
        let major = numbers.first ?? 0
        let minor = numbers.dropFirst().first ?? 0
        let modernGuards = major > 2 || (major == 2 && minor >= 7)
        let quoted = major > 3 || (major == 3 && minor >= 1)
        return TmuxProtocolDialect(
            commandGuardShape: modernGuards ? .threeFields : .twoFields,
            snapshotCodec: quoted ? .quoted : .legacyPerField
        )
    }

    private struct TmuxStaticRuntime: Sendable {
        let configuration: TmuxProviderConfiguration
        let runtime: PreparedRemoteScriptRuntime
        let executable: TmuxExecutablePath
        let version: String
    }

    private struct BootstrapResult: Sendable {
        let sessionID: TmuxSessionID
        let token: TmuxServerInstanceToken
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
        var newArguments = ["new-session", "-d", "-P", "-F", "#{session_id}"]
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
              let sessionID = try? decodeSessionID(lines[0]),
              let pid = Int32(lines[2]),
              let start = Int64(lines[3]),
              !lines[1].isEmpty
        else {
            throw TmuxProviderError.malformedProbeOutput
        }
        do {
            return BootstrapResult(
                sessionID: sessionID,
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
        from profile: TerminalBackendProfile
    ) throws -> TmuxProviderConfiguration {
        guard profile.providerID == Self.providerID,
              profile.configurationVersion == Self.configurationVersion
        else {
            throw PersistentTerminalError.invalidConfiguration
        }
        guard let data = profile.configurationJSON.data(using: .utf8) else {
            throw PersistentTerminalError.invalidConfiguration
        }
        do {
            let configuration = try JSONDecoder().decode(TmuxProviderConfiguration.self, from: data)
            guard profile.providerConfigurationKey == configuration.locator.configurationKey else {
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

        let tmuxPathResult = try await execute(
            script: "command -v tmux",
            runtime: runtime,
            in: context
        )
        guard tmuxPathResult.isSuccess else {
            throw PersistentTerminalError.executableMissing
        }
        let executable: TmuxExecutablePath
        do {
            executable = try TmuxExecutablePath(decodeExecutablePath(tmuxPathResult.stdout))
        } catch {
            throw PersistentTerminalError.invalidConfiguration
        }

        let versionResult = try await execute(
            script: tmuxScript(
                executable: executable,
                locator: configuration.locator,
                arguments: ["-V"]
            ),
            runtime: runtime,
            in: context
        )
        guard versionResult.isSuccess else {
            throw PersistentTerminalError.incompatibleVersion(versionResult.stderrText)
        }
        let version = decodeVersion(versionResult.stdout)
        guard !version.isEmpty else {
            throw PersistentTerminalError.incompatibleVersion(nil)
        }

        let commands = try await execute(
            script: tmuxScript(
                executable: executable,
                locator: configuration.locator,
                arguments: ["list-commands"]
            ),
            runtime: runtime,
            in: context
        )
        guard commands.isSuccess else {
            throw commandRejected(commands)
        }
        return TmuxStaticRuntime(
            configuration: configuration,
            runtime: runtime,
            executable: executable,
            version: version
        )
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
        try await context.session.exec(try runtime.invocation(for: script), timeout: .seconds(30))
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

    private func decodeFirstSessionID(_ data: Data) throws -> TmuxSessionID {
        let ids = try decodeSessionIDs(data)
        guard let id = ids.first, ids.count == 1 else {
            throw TmuxProviderError.malformedProbeOutput
        }
        return id
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
        profileID: String,
        freshness: PersistentWorkspaceCatalogFreshness
    ) throws -> PersistentWorkspaceCatalogSnapshot {
        let observedAt: Date = switch freshness {
        case let .liveSubscription(observedAt), let .snapshot(observedAt): observedAt
        case let .stale(lastObservedAt): lastObservedAt ?? Date()
        case .unavailable: Date()
        }
        return PersistentWorkspaceCatalogSnapshot(
            providerID: Self.providerID,
            profileID: profileID,
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
            profileID: context.backendProfile.id,
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
    package let descriptor: PersistentAttachmentDescriptor
    package let presentation: PersistentAttachmentPresentation
    package let runtimeAttachmentID: String
    package let attachmentGeneration: UInt64
    package var interaction: any PersistentTerminalInteractionFacet { interactionFacet }
    private let channel: TmuxProcessShellChannel
    private let interactionFacet: TmuxInteractionFacet
    private let lifecycleLock = NSLock()
    private var didClose = false

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
    }

    package func close() async {
        let shouldClose = lifecycleLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }
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
        profileID: String,
        instanceToken: TmuxServerInstanceToken,
        lease: TmuxProviderControlCatalogLease,
        controlCapabilities: TmuxNegotiatedCapabilities,
        controlConfiguration: TmuxControlClientConfiguration
    ) {
        let (snapshots, continuation) = AsyncStream<PersistentWorkspaceCatalogSnapshot>.makeStream()
        let (topology, topologyContinuation) = AsyncStream<TmuxServerSnapshot>.makeStream()
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
                    profileID: profileID,
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
        profileID: String,
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
            profileID: profileID,
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
            self?.degradeReadiness()
        }
        defer { timeout.cancel() }
        processIdentity = try await gate.waitForReady()
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
        var shouldDegrade = false
        lock.lock()
        if didResolveReadiness {
            lock.unlock()
            outputContinuation.yield(data)
            return
        }

        preamble.append(data)
        if preamble.count > 4 * 1_024 {
            didResolveReadiness = true
            bufferedOutput = preamble
            preamble.removeAll(keepingCapacity: true)
            preambleScanOffset = 0
            shouldDegrade = true
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
        } else if shouldDegrade {
            gate.ready(nil)
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

    private func degradeReadiness() {
        let bufferedOutput: Data? = lock.withLock {
            guard !didResolveReadiness else { return nil }
            didResolveReadiness = true
            let buffered = preamble
            preamble.removeAll(keepingCapacity: true)
            preambleScanOffset = 0
            return buffered
        }
        guard bufferedOutput != nil else { return }
        gate.ready(nil)
        if let bufferedOutput, !bufferedOutput.isEmpty {
            outputContinuation.yield(bufferedOutput)
        }
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
