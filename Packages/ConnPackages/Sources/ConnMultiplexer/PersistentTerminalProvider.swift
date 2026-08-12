import ConnKit
import ConnSSH

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
