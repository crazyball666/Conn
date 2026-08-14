import ConnKit
import ConnSSH

public enum PersistentTerminalProviderRegistryError: Error, Sendable, Equatable {
    case emptyProviderID
    case duplicateProviderID(String)
}

/// Immutable provider registry with deterministic, exact routing and no fallback provider.
public struct PersistentTerminalProviderRegistry: Sendable {
    private let providersByID: [String: any PersistentTerminalProvider]

    /// The product's current built-in provider set. Callers that need plugins or a
    /// platform-specific provider should still construct an explicit registry; this
    /// property is only the composition-root default and does not add fallback routing.
    public static let `default`: Self = {
        do {
            return try Self(providers: [TmuxProvider()])
        } catch {
            preconditionFailure("built-in persistent-terminal providers must have unique IDs")
        }
    }()

    public init(providers: [any PersistentTerminalProvider]) throws {
        if providers.contains(where: { $0.descriptor.id.isEmpty }) {
            throw PersistentTerminalProviderRegistryError.emptyProviderID
        }

        let duplicateID = Dictionary(grouping: providers, by: { $0.descriptor.id })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
            .first
        if let duplicateID {
            throw PersistentTerminalProviderRegistryError.duplicateProviderID(duplicateID)
        }

        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
    }

    public func provider(
        for profile: TerminalBackendProfile,
        platform: RemotePlatformKind
    ) throws -> any PersistentTerminalProvider {
        guard profile.isEnabled else {
            throw PersistentTerminalError.providerDisabled
        }
        guard let provider = providersByID[profile.providerID] else {
            throw PersistentTerminalError.providerNotRegistered(profile.providerID)
        }
        try validatePlatform(platform, for: provider)
        try validateConfiguration(profile, for: provider)
        return provider
    }

    /// Probes through the registry so a provider cannot advertise negotiated capabilities
    /// outside the static feature ceiling declared by its descriptor.
    public func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
        let provider = try provider(
            for: context.backendProfile,
            platform: context.platformProfile.kind
        )
        let availability = try await provider.probe(in: context)
        guard availability.effectiveFeatures.isSubset(of: provider.descriptor.potentialFeatures) else {
            throw PersistentTerminalError.protocolViolation
        }
        if let instance = availability.instance,
           !provider.descriptor.supportedWorkspaceInstancePayloadVersions.contains(instance.payloadVersion) {
            throw PersistentTerminalError.unsupportedDescriptorVersion(
                providerID: provider.descriptor.id,
                component: .workspaceInstance,
                version: instance.payloadVersion
            )
        }
        return availability
    }

    public func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment {
        guard let provider = providersByID[descriptor.providerID] else {
            throw PersistentTerminalError.providerNotRegistered(descriptor.providerID)
        }

        try validatePlatform(context.platformProfile.kind, for: provider)
        try validateProfile(context.backendProfile, against: descriptor, for: provider)
        try validateVersions(descriptor, for: provider)

        return try await provider.openAttachment(
            descriptor,
            reason: reason,
            terminalSize: terminalSize,
            in: context
        )
    }

    public func openCatalog(
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalCatalogAttachment {
        let provider = try provider(
            for: context.backendProfile,
            platform: context.platformProfile.kind
        )
        guard let catalogProvider = provider as? any PersistentTerminalCatalogProvider else {
            throw PersistentTerminalError.unsupportedFeature(
                providerID: provider.descriptor.id,
                feature: "workspaceCatalog"
            )
        }
        return try await catalogProvider.openCatalog(in: context)
    }

    private func validatePlatform(
        _ platform: RemotePlatformKind,
        for provider: any PersistentTerminalProvider
    ) throws {
        guard provider.descriptor.supportedPlatforms.contains(platform) else {
            throw PersistentTerminalError.unsupportedPlatform
        }
    }

    private func validateConfiguration(
        _ profile: TerminalBackendProfile,
        for provider: any PersistentTerminalProvider
    ) throws {
        guard provider.descriptor.supportedConfigurationVersions.contains(profile.configurationVersion) else {
            throw PersistentTerminalError.incompatibleVersion(
                "profile configuration \(profile.configurationVersion)"
            )
        }
    }

    private func validateProfile(
        _ profile: TerminalBackendProfile,
        against descriptor: PersistentAttachmentDescriptor,
        for provider: any PersistentTerminalProvider
    ) throws {
        guard profile.isEnabled else {
            throw PersistentTerminalError.providerDisabled
        }
        guard profile.id == descriptor.profileID,
              profile.providerID == descriptor.providerID,
              profile.providerID == provider.descriptor.id
        else {
            throw PersistentTerminalError.profileUnavailable(descriptor.profileID)
        }
        try validateConfiguration(profile, for: provider)
    }

    private func validateVersions(
        _ descriptor: PersistentAttachmentDescriptor,
        for provider: any PersistentTerminalProvider
    ) throws {
        guard provider.descriptor.supportedWorkspaceInstancePayloadVersions.contains(
            descriptor.workspace.instancePayloadVersion
        ) else {
            throw PersistentTerminalError.unsupportedDescriptorVersion(
                providerID: descriptor.providerID,
                component: .workspaceInstance,
                version: descriptor.workspace.instancePayloadVersion
            )
        }
        guard provider.descriptor.supportedAttachmentPayloadVersions.contains(
            descriptor.payloadVersion
        ) else {
            throw PersistentTerminalError.unsupportedDescriptorVersion(
                providerID: descriptor.providerID,
                component: .attachment,
                version: descriptor.payloadVersion
            )
        }
    }
}
