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

/// Provider-neutral launch metadata. The mutable workspace name is kept outside
/// the reconnect descriptor because it is presentation state, not remote identity.
public struct PersistentTerminalLaunch: Sendable, Equatable {
    public let descriptor: PersistentAttachmentDescriptor
    public let workspaceName: String

    public init(descriptor: PersistentAttachmentDescriptor, workspaceName: String) {
        self.descriptor = descriptor
        self.workspaceName = workspaceName
    }
}

/// A local startup option published by the provider registry. It is intentionally
/// independent of a host and remote availability: rendering the new-terminal UI
/// must never open SSH or mutate persistence.
public struct PersistentBackendOption: Identifiable, Sendable, Equatable {
    public let providerID: String
    public let displayName: String
    public let configuration: PersistentTerminalConfiguration

    public var id: String {
        "\(providerID):\(configuration.configurationKey)"
    }

    public init(
        providerID: String,
        displayName: String,
        configuration: PersistentTerminalConfiguration
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.configuration = configuration
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
/// by `TerminalSession`. Provider configuration is a value snapshot carried from
/// the registry into the descriptor; no database-backed configuration record participates.
public struct PersistentProviderBackend: Sendable {
    private let registry: PersistentTerminalProviderRegistry

    public init(registry: PersistentTerminalProviderRegistry = .default) {
        self.registry = registry
    }

    /// Returns deterministic local choices without acquiring a connection.
    public func options() -> [PersistentBackendOption] {
        registry.registeredDefaults().map { value in
            PersistentBackendOption(
                providerID: value.descriptor.id,
                displayName: value.descriptor.displayName,
                configuration: value.configuration
            )
        }
    }

    /// Materializes a descriptor for the selected provider. Existing workspaces
    /// are reused; an empty/server-absent provider creates exactly one workspace.
    public func defaultLaunch(
        for option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentTerminalLaunch {
        let (provider, context) = try await providerContext(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
        if let workspace = try await provider.listWorkspaces(in: context).first {
            return try makeLaunch(for: workspace, provider: provider, context: context)
        }
        let workspace = try await provider.createWorkspace(.init(), in: context)
        return try makeLaunch(for: workspace, provider: provider, context: context)
    }

    public func defaultDescriptor(
        for option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentAttachmentDescriptor {
        try await defaultLaunch(
            for: option,
            host: host,
            connectionManager: connectionManager
        ).descriptor
    }

    /// Queries only the explicitly selected option. The catalog operation itself is
    /// the authoritative availability check; probing first would repeat every remote
    /// runtime/identity round trip immediately before the same provider does it again.
    public func workspaceOptions(
        for option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> [RemoteWorkspaceSummary] {
        let (provider, context) = try await providerContext(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
        return try await provider.listWorkspaces(in: context)
    }

    public func createLaunch(
        for selection: PersistentWorkspaceCreateSelection,
        option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentTerminalLaunch {
        let (provider, context) = try await providerContext(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
        let workspace = try await provider.createWorkspace(
            CreateWorkspaceRequest(name: selection.name),
            in: context
        )
        return try makeLaunch(for: workspace, provider: provider, context: context)
    }

    public func createDescriptor(
        for selection: PersistentWorkspaceCreateSelection,
        option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentAttachmentDescriptor {
        try await createLaunch(
            for: selection,
            option: option,
            host: host,
            connectionManager: connectionManager
        ).descriptor
    }

    public func open(
        _ descriptor: PersistentAttachmentDescriptor,
        for host: ConnKit.Host,
        connectionManager: ConnectionManager,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize
    ) async throws -> PersistentBackendOpening {
        let platformContext = try await connectionManager.platformContext(for: host)
        let context = PersistentTerminalContext(
            platformContext: platformContext,
            backendConfiguration: descriptor.configuration
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
        for option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> any PersistentTerminalCatalogAttachment {
        let (_, context) = try await providerContext(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
        return try await registry.openCatalog(in: context)
    }

    public func descriptor(
        for workspace: RemoteWorkspaceRef,
        option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentAttachmentDescriptor {
        let (provider, context) = try await providerContext(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
        return try provider.makeAttachmentDescriptor(to: workspace, in: context)
    }

    public func launch(
        for workspace: RemoteWorkspaceSummary,
        option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> PersistentTerminalLaunch {
        let (provider, context) = try await providerContext(
            for: option,
            host: host,
            connectionManager: connectionManager
        )
        return try makeLaunch(for: workspace, provider: provider, context: context)
    }

    public func renameWorkspace(
        _ descriptor: PersistentAttachmentDescriptor,
        to newName: String,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws {
        guard descriptor.providerID == descriptor.configuration.providerID else {
            throw PersistentTerminalError.invalidConfiguration
        }
        let platformContext = try await connectionManager.platformContext(for: host)
        let context = PersistentTerminalContext(
            platformContext: platformContext,
            backendConfiguration: descriptor.configuration
        )
        let provider = try registry.provider(
            for: descriptor.configuration,
            platform: context.platformProfile.kind
        )
        try await provider.renameWorkspace(descriptor.workspace, to: newName, in: context)
    }

    private func makeLaunch(
        for workspace: RemoteWorkspaceSummary,
        provider: any PersistentTerminalProvider,
        context: PersistentTerminalContext
    ) throws -> PersistentTerminalLaunch {
        PersistentTerminalLaunch(
            descriptor: try provider.makeAttachmentDescriptor(
                to: workspace.workspace,
                in: context
            ),
            workspaceName: workspace.name
        )
    }

    private func providerContext(
        for option: PersistentBackendOption,
        host: ConnKit.Host,
        connectionManager: ConnectionManager
    ) async throws -> (any PersistentTerminalProvider, PersistentTerminalContext) {
        guard option.providerID == option.configuration.providerID else {
            throw PersistentTerminalError.invalidConfiguration
        }
        let platformContext = try await connectionManager.platformContext(for: host)
        let context = PersistentTerminalContext(
            platformContext: platformContext,
            backendConfiguration: option.configuration
        )
        let provider = try registry.provider(
            for: option.configuration,
            platform: context.platformProfile.kind
        )
        return (provider, context)
    }
}
