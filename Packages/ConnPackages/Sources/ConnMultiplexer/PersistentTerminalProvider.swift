import ConnKit
import ConnSSH
import Foundation

public enum PersistentAttachmentPresentation: Sendable {
    case byteTerminal(any ShellChannel)
    // A future native renderer is added as another presentation/facet without changing
    // profiles, registry routing, or the durable descriptor envelope.
}

/// Runtime ownership handle for an opened persistent terminal attachment.
///
/// Implementations must make `close()` idempotent. Callers retain this handle for the full
/// tab lifetime instead of extracting and retaining only the byte channel.
public protocol PersistentTerminalAttachment: AnyObject, Sendable {
    var descriptor: PersistentAttachmentDescriptor { get }
    var presentation: PersistentAttachmentPresentation { get }
    func close() async
}

/// Provider-neutral projection of a remote workspace catalog. The provider owns the
/// subscription and its transport; the UI only receives bounded top-level summaries.
public enum PersistentWorkspaceCatalogFreshness: Sendable, Equatable {
    case liveSubscription(observedAt: Date)
    case snapshot(observedAt: Date)
    case stale(lastObservedAt: Date?)
    case unavailable
}

public struct PersistentWorkspaceCatalogSnapshot: Sendable, Equatable {
    public let providerID: String
    public let profileID: String
    public let instance: PersistentTerminalProviderInstance?
    public let workspaces: [RemoteWorkspaceSummary]
    public let freshness: PersistentWorkspaceCatalogFreshness
    public let observedAt: Date

    public init(
        providerID: String,
        profileID: String,
        instance: PersistentTerminalProviderInstance?,
        workspaces: [RemoteWorkspaceSummary],
        freshness: PersistentWorkspaceCatalogFreshness,
        observedAt: Date
    ) {
        self.providerID = providerID
        self.profileID = profileID
        self.instance = instance
        self.workspaces = workspaces
        self.freshness = freshness
        self.observedAt = observedAt
    }
}

public protocol PersistentTerminalCatalogAttachment: AnyObject, Sendable {
    var snapshots: AsyncStream<PersistentWorkspaceCatalogSnapshot> { get }
    func close() async
}

/// tmux's richer Session → Window → Pane graph remains a provider facet. Consumers that
/// need native management can opt into this protocol without making the generic terminal
/// coordinator understand tmux objects or commands.
public protocol TmuxWorkspaceCatalogManaging: PersistentTerminalCatalogAttachment {
    var topology: AsyncStream<TmuxServerSnapshot> { get }
    /// Capabilities are observed from this ready Control Mode client, not inferred from the
    /// tmux version string. Consumers can keep advanced UI/actions disabled when absent.
    var controlCapabilities: TmuxNegotiatedCapabilities { get }
    var controlConfiguration: TmuxControlClientConfiguration { get }
    /// Computes the validated shared-state impact against the latest topology without
    /// submitting a command. Management UI uses this before every mutation.
    func previewImpact(_ operation: TmuxOperation) async throws -> TmuxOperationImpact
    func execute(_ operation: TmuxOperation) async throws
    func prepareDestructive(
        _ operation: TmuxOperation
    ) async throws -> TmuxPreparedDestructiveOperation
    func executeDestructive(
        _ prepared: TmuxPreparedDestructiveOperation
    ) async throws
}

/// Optional facet for providers that can keep a live remote workspace catalog. Providers
/// without this facet still participate in the base attachment lifecycle unchanged.
public protocol PersistentTerminalCatalogProvider: PersistentTerminalProvider {
    func openCatalog(
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalCatalogAttachment
}

/// One atomically claimed SSH connection/platform context plus its durable backend profile.
public struct PersistentTerminalContext: Sendable {
    public let connectionIdentity: SSHConnectionIdentity
    public let session: any SSHSession
    public let platformProfile: RemotePlatformProfile
    public let backendProfile: TerminalBackendProfile

    /// Deliberately accepts `RemotePlatformContext` as one value so callers cannot stitch a
    /// session, platform profile, and connection identity from different pool generations.
    public init(
        platformContext: RemotePlatformContext,
        backendProfile: TerminalBackendProfile
    ) throws {
        guard platformContext.connectionIdentity.hostID == backendProfile.hostID else {
            throw PersistentTerminalError.profileUnavailable(backendProfile.id)
        }

        connectionIdentity = platformContext.connectionIdentity
        session = platformContext.session
        platformProfile = platformContext.profile
        self.backendProfile = backendProfile
    }
}

/// Complete provider-neutral lifecycle for a top-level persistent terminal workspace.
public protocol PersistentTerminalProvider: Sendable {
    var descriptor: PersistentTerminalProviderDescriptor { get }

    func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability
    func listWorkspaces(in context: PersistentTerminalContext) async throws -> [RemoteWorkspaceSummary]
    func createWorkspace(
        _ request: CreateWorkspaceRequest,
        in context: PersistentTerminalContext
    ) async throws -> RemoteWorkspaceRef
    func renameWorkspace(
        _ workspace: RemoteWorkspaceRef,
        to newName: String,
        in context: PersistentTerminalContext
    ) async throws
    func destroyWorkspace(
        _ workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) async throws
    func makeAttachmentDescriptor(
        to workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) throws -> PersistentAttachmentDescriptor
    func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment
}
