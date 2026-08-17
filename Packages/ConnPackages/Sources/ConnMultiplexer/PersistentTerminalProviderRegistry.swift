import ConnKit
import ConnSSH
import Foundation

public enum PersistentTerminalProviderRegistryError: Error, Sendable, Equatable {
    case emptyProviderID
    case duplicateProviderID(String)
    case defaultConfigurationProviderMismatch(providerID: String, configurationProviderID: String)
    case unsupportedDefaultConfigurationVersion(providerID: String, version: Int)
}

public struct PersistentTerminalProviderDefault: Sendable, Equatable {
    public let descriptor: PersistentTerminalProviderDescriptor
    public let configuration: PersistentTerminalConfiguration

    public init(
        descriptor: PersistentTerminalProviderDescriptor,
        configuration: PersistentTerminalConfiguration
    ) {
        self.descriptor = descriptor
        self.configuration = configuration
    }
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

        for provider in providers {
            let configuration = provider.defaultConfiguration
            guard configuration.providerID == provider.descriptor.id else {
                throw PersistentTerminalProviderRegistryError.defaultConfigurationProviderMismatch(
                    providerID: provider.descriptor.id,
                    configurationProviderID: configuration.providerID
                )
            }
            guard provider.descriptor.supportedConfigurationVersions.contains(
                configuration.payloadVersion
            ) else {
                throw PersistentTerminalProviderRegistryError.unsupportedDefaultConfigurationVersion(
                    providerID: provider.descriptor.id,
                    version: configuration.payloadVersion
                )
            }
        }

        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
    }

    public func registeredDefaults() -> [PersistentTerminalProviderDefault] {
        providersByID.values
            .sorted { $0.descriptor.id < $1.descriptor.id }
            .map {
                PersistentTerminalProviderDefault(
                    descriptor: $0.descriptor,
                    configuration: $0.defaultConfiguration
                )
            }
    }

    public func provider(
        for configuration: PersistentTerminalConfiguration,
        platform: RemotePlatformKind
    ) throws -> any PersistentTerminalProvider {
        guard let provider = providersByID[configuration.providerID] else {
            throw PersistentTerminalError.providerNotRegistered(configuration.providerID)
        }
        try validatePlatform(platform, for: provider)
        try validateConfiguration(configuration, for: provider)
        return provider
    }

    /// Probes through the registry so a provider cannot advertise negotiated capabilities
    /// outside the static feature ceiling declared by its descriptor.
    public func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
        let provider = try provider(
            for: context.backendConfiguration,
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
        try validateConfiguration(context.backendConfiguration, against: descriptor, for: provider)
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
            for: context.backendConfiguration,
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
        _ configuration: PersistentTerminalConfiguration,
        for provider: any PersistentTerminalProvider
    ) throws {
        guard provider.descriptor.supportedConfigurationVersions.contains(
            configuration.payloadVersion
        ) else {
            throw PersistentTerminalError.unsupportedConfigurationVersion(
                providerID: provider.descriptor.id,
                version: configuration.payloadVersion
            )
        }
    }

    private func validateConfiguration(
        _ configuration: PersistentTerminalConfiguration,
        against descriptor: PersistentAttachmentDescriptor,
        for provider: any PersistentTerminalProvider
    ) throws {
        guard configuration == descriptor.configuration,
              configuration.providerID == descriptor.providerID,
              configuration.providerID == provider.descriptor.id
        else {
            throw PersistentTerminalError.invalidConfiguration
        }
        try validateConfiguration(configuration, for: provider)
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
