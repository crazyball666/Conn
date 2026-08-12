import ConnKit
import Foundation

/// Provider capabilities that are meaningful across persistent-terminal implementations.
public enum PersistentTerminalFeature: String, Codable, Sendable, Hashable, CaseIterable {
    case workspaceDiscovery
    case workspaceCreation
    case workspaceRename
    case workspaceDestruction
    case eventStreaming
    case dynamicMetadataSubscriptions
    case clientInspection
    case clientManagement
    case hierarchicalWindows
    case hierarchicalPanes
    case readOnlyAttach
    case snapshotPreview
    case nativePaneOutput
}

/// Static metadata and compatibility bounds published by one provider implementation.
public struct PersistentTerminalProviderDescriptor: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let supportedPlatforms: Set<RemotePlatformKind>
    public let supportedConfigurationVersions: Set<Int>
    public let supportedWorkspaceInstancePayloadVersions: Set<Int>
    public let supportedAttachmentPayloadVersions: Set<Int>
    public let potentialFeatures: Set<PersistentTerminalFeature>

    public init(
        id: String,
        displayName: String,
        supportedPlatforms: Set<RemotePlatformKind>,
        supportedConfigurationVersions: Set<Int>,
        supportedWorkspaceInstancePayloadVersions: Set<Int>,
        supportedAttachmentPayloadVersions: Set<Int>,
        potentialFeatures: Set<PersistentTerminalFeature>
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedPlatforms = supportedPlatforms
        self.supportedConfigurationVersions = supportedConfigurationVersions
        self.supportedWorkspaceInstancePayloadVersions = supportedWorkspaceInstancePayloadVersions
        self.supportedAttachmentPayloadVersions = supportedAttachmentPayloadVersions
        self.potentialFeatures = potentialFeatures
    }
}

/// A stable top-level workspace reference within one provider server instance.
public struct RemoteWorkspaceRef: Sendable, Codable, Equatable {
    public let workspaceID: String
    public let instancePayloadVersion: Int
    public let providerInstancePayload: Data

    public init(
        workspaceID: String,
        instancePayloadVersion: Int,
        providerInstancePayload: Data
    ) {
        self.workspaceID = workspaceID
        self.instancePayloadVersion = instancePayloadVersion
        self.providerInstancePayload = providerInstancePayload
    }
}

/// Durable, provider-neutral information required to open or reconnect an attachment.
public struct PersistentAttachmentDescriptor: Sendable, Codable, Equatable {
    public let providerID: String
    public let profileID: String
    public let workspace: RemoteWorkspaceRef
    public let payloadVersion: Int
    public let providerPayload: Data

    public init(
        providerID: String,
        profileID: String,
        workspace: RemoteWorkspaceRef,
        payloadVersion: Int,
        providerPayload: Data
    ) {
        self.providerID = providerID
        self.profileID = profileID
        self.workspace = workspace
        self.payloadVersion = payloadVersion
        self.providerPayload = providerPayload
    }
}

public enum PersistentAttachmentOpenReason: String, Codable, Sendable, Equatable {
    case initial
    case reconnect
}

public enum PersistentPayloadComponent: String, Codable, Sendable, Equatable {
    case workspaceInstance
    case attachment
}

/// Provider-specific server identity returned by a probe, kept opaque by shared code.
public struct PersistentTerminalProviderInstance: Sendable, Equatable {
    public let generation: UInt64
    public let payloadVersion: Int
    public let providerPayload: Data

    public init(
        generation: UInt64 = 0,
        payloadVersion: Int,
        providerPayload: Data
    ) {
        self.generation = generation
        self.payloadVersion = payloadVersion
        self.providerPayload = providerPayload
    }
}

public enum PersistentTerminalAvailabilityState: String, Sendable, Equatable {
    case available
    case degraded
    case unavailable
    case unsupported
}

/// Dynamic probe result. UI and operation guards must use `effectiveFeatures`, not the
/// provider descriptor's optimistic `potentialFeatures`.
public struct PersistentTerminalAvailability: Sendable, Equatable {
    public let state: PersistentTerminalAvailabilityState
    public let effectiveFeatures: Set<PersistentTerminalFeature>
    public let instance: PersistentTerminalProviderInstance?
    public let issue: PersistentTerminalError?
    public let observedAt: Date

    public init(
        state: PersistentTerminalAvailabilityState,
        effectiveFeatures: Set<PersistentTerminalFeature> = [],
        instance: PersistentTerminalProviderInstance? = nil,
        issue: PersistentTerminalError? = nil,
        observedAt: Date = Date()
    ) {
        self.state = state
        self.effectiveFeatures = effectiveFeatures
        self.instance = instance
        self.issue = issue
        self.observedAt = observedAt
    }
}

public enum RemoteWorkspaceFreshness: String, Codable, Sendable, Equatable {
    case fresh
    case stale
    case unknown
}

/// Other clients or attachments that would be affected by a destructive workspace action.
public struct RemoteWorkspaceOccupancy: Codable, Sendable, Equatable {
    public let affectedAttachmentCount: Int?
    public let observedAt: Date
    public let freshness: RemoteWorkspaceFreshness

    public init(
        affectedAttachmentCount: Int?,
        observedAt: Date,
        freshness: RemoteWorkspaceFreshness
    ) {
        self.affectedAttachmentCount = affectedAttachmentCount
        self.observedAt = observedAt
        self.freshness = freshness
    }
}

/// Provider-independent catalog row. Provider-specific Window/Pane topology stays in facets.
public struct RemoteWorkspaceSummary: Codable, Sendable, Equatable {
    public let workspace: RemoteWorkspaceRef
    public let name: String
    public let createdAt: Date?
    public let lastActivityAt: Date?
    public let occupancy: RemoteWorkspaceOccupancy
    public let status: String?

    public init(
        workspace: RemoteWorkspaceRef,
        name: String,
        createdAt: Date? = nil,
        lastActivityAt: Date? = nil,
        occupancy: RemoteWorkspaceOccupancy,
        status: String? = nil
    ) {
        self.workspace = workspace
        self.name = name
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.occupancy = occupancy
        self.status = status
    }
}

/// Common inputs for creating a top-level workspace. Provider-specific defaults belong to
/// the selected backend profile rather than leaking into this envelope.
public struct CreateWorkspaceRequest: Codable, Sendable, Equatable {
    public let name: String?

    public init(name: String? = nil) {
        self.name = name
    }
}

public enum PersistentTerminalError: Error, Sendable, Equatable {
    case unsupportedPlatform
    case providerNotRegistered(String)
    case providerDisabled
    case profileUnavailable(String)
    case executableMissing
    case incompatibleVersion(String?)
    case serverUnavailable
    case socketPermissionDenied
    case invalidConfiguration
    case unsupportedDescriptorVersion(
        providerID: String,
        component: PersistentPayloadComponent,
        version: Int
    )
    case unsupportedFeature(providerID: String, feature: String)
    case controlModeUnavailable
    case protocolViolation
    case serverInstanceChanged
    case bootstrapPreconditionChanged
    case staleConfirmation
    case staleTarget
    case remoteObjectMissing
    case commandRejected(String)
    case operationOutcomeUnknown
    case transportClosed
}
