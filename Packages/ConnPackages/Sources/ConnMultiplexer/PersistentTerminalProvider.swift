import ConnKit
import ConnSSH
import Foundation

public enum PersistentAttachmentPresentation: Sendable {
    case byteTerminal(any ShellChannel)
    // A future native renderer is added as another presentation/facet without changing
    // configuration routing or the durable descriptor envelope.
}

/// Stable identity for one required runtime component owned by an attachment.
/// It deliberately is not an enum so future providers can add components independently.
public struct PersistentTerminalRuntimeComponentID:
    RawRepresentable,
    Hashable,
    Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

public enum PersistentTerminalAttachmentRecovery: Sendable, Equatable {
    /// Recreate the complete attachment through the same startup pipeline.
    case rebuildAttachment
    /// Preserve the disconnected tab and wait for explicit user action.
    case manual
}

public struct PersistentTerminalAttachmentFailure: Sendable, Equatable {
    public let componentID: PersistentTerminalRuntimeComponentID
    public let issue: PersistentTerminalError
    public let recovery: PersistentTerminalAttachmentRecovery

    public init(
        componentID: PersistentTerminalRuntimeComponentID,
        issue: PersistentTerminalError,
        recovery: PersistentTerminalAttachmentRecovery
    ) {
        self.componentID = componentID
        self.issue = issue
        self.recovery = recovery
    }
}

public enum PersistentTerminalAttachmentLifecycleEvent: Sendable, Equatable {
    /// The attached remote workspace ended normally. Consumers should retire the local
    /// terminal and its durable resume bookmark instead of offering an impossible reconnect.
    case workspaceClosed
    case failed(PersistentTerminalAttachmentFailure)
}

/// Defines which side owns the visible terminal image and its effective PTY size.
/// Ordinary shells keep using the local transcript. Providers such as tmux can instead
/// rebuild the screen from their authoritative remote state whenever a view is attached.
public enum PersistentTerminalViewportAuthority: Sendable, Equatable {
    case localTranscript
    case remoteProvider
}

public enum PersistentTerminalViewportState: Sendable, Equatable {
    case hidden
    case visible(TermSize)
}

/// Runtime ownership handle for an opened persistent terminal attachment.
///
/// Implementations must make `close()` idempotent. Callers retain this handle for the full
/// tab lifetime instead of extracting and retaining only the byte channel.
public protocol PersistentTerminalAttachment: AnyObject, Sendable {
    var descriptor: PersistentAttachmentDescriptor { get }
    var presentation: PersistentAttachmentPresentation { get }
    var lifecycleEvents: AsyncStream<PersistentTerminalAttachmentLifecycleEvent> { get }
    var viewportAuthority: PersistentTerminalViewportAuthority { get }
    func updateViewport(_ state: PersistentTerminalViewportState) async throws
    func close() async
}

public extension PersistentTerminalAttachment {
    /// Simple providers own only their presentation channel, whose lifecycle is already
    /// observed by `TerminalSession`. Composite providers override this stream.
    var lifecycleEvents: AsyncStream<PersistentTerminalAttachmentLifecycleEvent> {
        AsyncStream { $0.finish() }
    }

    var viewportAuthority: PersistentTerminalViewportAuthority { .localTranscript }

    func updateViewport(_: PersistentTerminalViewportState) async throws {}
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
    public let configurationKey: String
    public let instance: PersistentTerminalProviderInstance?
    public let workspaces: [RemoteWorkspaceSummary]
    public let freshness: PersistentWorkspaceCatalogFreshness
    public let observedAt: Date

    public init(
        providerID: String,
        configurationKey: String,
        instance: PersistentTerminalProviderInstance?,
        workspaces: [RemoteWorkspaceSummary],
        freshness: PersistentWorkspaceCatalogFreshness,
        observedAt: Date
    ) {
        self.providerID = providerID
        self.configurationKey = configurationKey
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

/// Catalog and topology values are replaceable state, not an event log. Keeping this
/// construction provider-neutral prevents a slow or absent UI consumer from retaining every
/// historical server snapshot.
public enum PersistentTerminalCatalogStreams {
    public static func makeStateStream<Element: Sendable>(
        of _: Element.Type = Element.self,
        bufferingNewest limit: Int = 1
    ) -> (
        stream: AsyncStream<Element>,
        continuation: AsyncStream<Element>.Continuation
    ) {
        AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(max(limit, 1)))
    }
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

/// One atomically claimed SSH connection/platform context plus an immutable backend configuration.
public struct PersistentTerminalContext: Sendable {
    public let connectionIdentity: SSHConnectionIdentity
    public let session: any SSHSession
    public let platformProfile: RemotePlatformProfile
    public let backendConfiguration: PersistentTerminalConfiguration

    /// Deliberately accepts `RemotePlatformContext` as one value so callers cannot stitch a
    /// session, platform profile, and connection identity from different pool generations.
    public init(
        platformContext: RemotePlatformContext,
        backendConfiguration: PersistentTerminalConfiguration
    ) {
        connectionIdentity = platformContext.connectionIdentity
        session = platformContext.session
        platformProfile = platformContext.profile
        self.backendConfiguration = backendConfiguration
    }
}

/// Complete provider-neutral lifecycle for a top-level persistent terminal workspace.
public protocol PersistentTerminalProvider: Sendable {
    var descriptor: PersistentTerminalProviderDescriptor { get }
    var defaultConfiguration: PersistentTerminalConfiguration { get }

    /// Read-only diagnostics/capability reporting. Operations below must remain
    /// independently self-validating; callers are not required to perform a duplicate
    /// probe immediately before a catalog query, mutation or attachment open.
    func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability
    func listWorkspaces(in context: PersistentTerminalContext) async throws -> [RemoteWorkspaceSummary]
    func createWorkspace(
        _ request: CreateWorkspaceRequest,
        in context: PersistentTerminalContext
    ) async throws -> RemoteWorkspaceSummary
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
