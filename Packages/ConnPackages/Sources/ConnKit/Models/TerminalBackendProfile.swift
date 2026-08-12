import Foundation

/// A durable, provider-neutral configuration for a persistent terminal backend.
///
/// Provider-specific configuration remains opaque in ConnKit. The provider that owns
/// `providerID` is solely responsible for decoding `configurationJSON` at the declared version.
public struct TerminalBackendProfile: Identifiable, Codable, Sendable, Equatable {
    public struct Identity: Codable, Sendable, Equatable, Hashable {
        public let profileID: String
        public let hostID: String
        public let providerID: String
        public let providerConfigurationKey: String

        public init(
            profileID: String,
            hostID: String,
            providerID: String,
            providerConfigurationKey: String
        ) {
            self.profileID = profileID
            self.hostID = hostID
            self.providerID = providerID
            self.providerConfigurationKey = providerConfigurationKey
        }
    }

    public let id: String
    public let hostID: String
    public let providerID: String
    public let providerConfigurationKey: String
    public var displayName: String
    public var isEnabled: Bool
    public var isPrimary: Bool
    public var configurationVersion: Int
    public var configurationJSON: String
    public var sortOrder: Int
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool

    public init(
        id: String = UUID().uuidString,
        hostID: String,
        providerID: String,
        providerConfigurationKey: String,
        displayName: String,
        isEnabled: Bool = true,
        isPrimary: Bool = false,
        configurationVersion: Int = 1,
        configurationJSON: String,
        sortOrder: Int = 0,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.providerID = providerID
        self.providerConfigurationKey = providerConfigurationKey
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.isPrimary = isPrimary
        self.configurationVersion = configurationVersion
        self.configurationJSON = configurationJSON
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
    }

    public var identity: Identity {
        Identity(
            profileID: id,
            hostID: hostID,
            providerID: providerID,
            providerConfigurationKey: providerConfigurationKey
        )
    }
}
