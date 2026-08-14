import ConnKit
import ConnMultiplexer
import ConnSSH
import Foundation

/// The result a terminal coordinator needs from any persistent provider: a byte
/// presentation plus the provider-owned lifetime handle.
public struct PersistentBackendOpening: Sendable {
    public let channel: any ShellChannel
    public let attachment: any PersistentTerminalAttachment

    public init(
        channel: any ShellChannel,
        attachment: any PersistentTerminalAttachment
    ) {
        self.channel = channel
        self.attachment = attachment
    }
}

/// A provider-neutral option for a terminal startup selector. `availability` is
/// dynamic and may be degraded (for example, tmux has no running server yet); an
/// unavailable POSIX provider is intentionally not surfaced as a usable option.
public struct PersistentBackendCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    public let providerID: String
    public let profileID: String
    public let displayName: String
    public let availability: PersistentTerminalAvailabilityState
    public let issue: PersistentTerminalError?

    public init(
        providerID: String,
        profileID: String,
        displayName: String,
        availability: PersistentTerminalAvailabilityState,
        issue: PersistentTerminalError? = nil
    ) {
        id = profileID
        self.providerID = providerID
        self.profileID = profileID
        self.displayName = displayName
        self.availability = availability
        self.issue = issue
    }
}

/// Explicit startup choice for creating a new provider workspace.
public struct PersistentWorkspaceCreateSelection: Sendable, Equatable {
    public let name: String?

    public init(name: String? = nil) {
        self.name = name
    }
}

/// Generic bridge from a durable attachment descriptor to the byte terminal used
/// by `TerminalSession`. It deliberately has no tmux/Zellij/Screen switch; adding
/// another provider only changes the registry supplied at the composition root.
public struct PersistentProviderBackend: Sendable {
    private let registry: PersistentTerminalProviderRegistry
    private let profileRepository: any TerminalBackendProfileRepository

    public init(
        registry: PersistentTerminalProviderRegistry = .default,
        profileRepository: any TerminalBackendProfileRepository
    ) {
        self.registry = registry
        self.profileRepository = profileRepository
    }

    /// Probes all configured providers for one host. It never falls back inside
    /// the provider registry; the caller may offer plain PTY alongside these
    /// candidates when a candidate is unavailable.
    public func candidates(
        for host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async -> [PersistentBackendCandidate] {
        let profiles = ((try? profileRepository.profiles(hostID: host.id, providerID: nil)) ?? [])
            .sorted {
                if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id < $1.id
            }
        var candidates: [PersistentBackendCandidate] = []
        for profile in profiles where profile.isEnabled {
            do {
                let platform = try await connectionManager.platformContext(for: host)
                let context = try PersistentTerminalContext(
                    platformContext: platform,
                    backendProfile: profile
                )
                let availability = try await registry.probe(in: context)
                candidates.append(PersistentBackendCandidate(
                    providerID: profile.providerID,
                    profileID: profile.id,
                    displayName: profile.displayName,
                    availability: availability.state,
                    issue: availability.issue
                ))
            } catch let issue as PersistentTerminalError {
                candidates.append(PersistentBackendCandidate(
                    providerID: profile.providerID,
                    profileID: profile.id,
                    displayName: profile.displayName,
                    availability: .unavailable,
                    issue: issue
                ))
            } catch {
                candidates.append(PersistentBackendCandidate(
                    providerID: profile.providerID,
                    profileID: profile.id,
                    displayName: profile.displayName,
                    availability: .unavailable,
                    issue: .transportClosed
                ))
            }
        }
        return candidates
    }

    /// Materializes a descriptor for the selected provider. Existing workspaces
    /// are reused; an empty/server-absent provider creates exactly one workspace
    /// through its typed lifecycle API.
    public func defaultDescriptor(
        for candidate: PersistentBackendCandidate,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentAttachmentDescriptor {
        guard let profile = try profileRepository.profile(id: candidate.profileID) else {
            throw PersistentTerminalError.profileUnavailable(candidate.profileID)
        }
        let platform = try await connectionManager.platformContext(for: host)
        let context = try PersistentTerminalContext(platformContext: platform, backendProfile: profile)
        let provider = try registry.provider(for: profile, platform: context.platformProfile.kind)
        if let workspace = try await provider.listWorkspaces(in: context).first {
            return try provider.makeAttachmentDescriptor(to: workspace.workspace, in: context)
        }
        let workspace = try await provider.createWorkspace(.init(), in: context)
        return try provider.makeAttachmentDescriptor(to: workspace, in: context)
    }

    /// Returns the current workspaces for an explicit startup picker. The caller decides
    /// which workspace to attach; this method never silently chooses the first row.
    public func workspaceOptions(
        for candidate: PersistentBackendCandidate,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> [RemoteWorkspaceSummary] {
        let (provider, context) = try await providerContext(
            for: candidate.profileID,
            providerID: candidate.providerID,
            host: host,
            connectionManager: connectionManager
        )
        return try await provider.listWorkspaces(in: context)
    }

    /// Creates a descriptor for a newly created workspace. Creation is explicit so a
    /// startup picker cannot accidentally attach the first existing Session.
    public func createDescriptor(
        for selection: PersistentWorkspaceCreateSelection,
        candidate: PersistentBackendCandidate,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentAttachmentDescriptor {
        let (provider, context) = try await providerContext(
            for: candidate.profileID,
            providerID: candidate.providerID,
            host: host,
            connectionManager: connectionManager
        )
        let workspace = try await provider.createWorkspace(
            CreateWorkspaceRequest(name: selection.name),
            in: context
        )
        return try provider.makeAttachmentDescriptor(to: workspace, in: context)
    }

    public func open(
        _ descriptor: PersistentAttachmentDescriptor,
        for host: ConnKit.Host,
        connectionManager: ConnectionManager,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize
    ) async throws -> PersistentBackendOpening {
        guard let profile = try profileRepository.profile(id: descriptor.profileID),
              profile.hostID == host.id
        else {
            throw PersistentTerminalError.profileUnavailable(descriptor.profileID)
        }

        // One atomic context keeps identity, platform and pooled SSH session in
        // lockstep. Providers never receive independently fetched pieces.
        let platformContext = try await connectionManager.platformContext(for: host)
        let context = try PersistentTerminalContext(
            platformContext: platformContext,
            backendProfile: profile
        )
        let attachment = try await registry.openAttachment(
            descriptor,
            reason: reason,
            terminalSize: terminalSize,
            in: context
        )
        guard case let .byteTerminal(channel) = attachment.presentation else {
            await attachment.close()
            throw PersistentTerminalError.unsupportedFeature(
                providerID: descriptor.providerID,
                feature: "byteTerminal"
            )
        }
        return PersistentBackendOpening(channel: channel, attachment: attachment)
    }

    public func openCatalog(
        for candidate: PersistentBackendCandidate,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> any PersistentTerminalCatalogAttachment {
        let (_, context) = try await providerContext(
            for: candidate.profileID,
            providerID: candidate.providerID,
            host: host,
            connectionManager: connectionManager
        )
        return try await registry.openCatalog(in: context)
    }

    public func descriptor(
        for workspace: RemoteWorkspaceRef,
        providerID: String,
        profileID: String,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentAttachmentDescriptor {
        guard let profile = try profileRepository.profile(id: profileID),
              profile.hostID == host.id,
              profile.providerID == providerID,
              profile.isEnabled
        else {
            throw PersistentTerminalError.profileUnavailable(profileID)
        }
        let platformContext = try await connectionManager.platformContext(for: host)
        let context = try PersistentTerminalContext(
            platformContext: platformContext,
            backendProfile: profile
        )
        let provider = try registry.provider(
            for: profile,
            platform: context.platformProfile.kind
        )
        return try provider.makeAttachmentDescriptor(to: workspace, in: context)
    }

    private func providerContext(
        for profileID: String,
        providerID: String,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> (any PersistentTerminalProvider, PersistentTerminalContext) {
        guard let profile = try profileRepository.profile(id: profileID),
              profile.hostID == host.id,
              profile.providerID == providerID
        else {
            throw PersistentTerminalError.profileUnavailable(profileID)
        }
        let platformContext = try await connectionManager.platformContext(for: host)
        let context = try PersistentTerminalContext(
            platformContext: platformContext,
            backendProfile: profile
        )
        let provider = try registry.provider(
            for: profile,
            platform: context.platformProfile.kind
        )
        return (provider, context)
    }
}
