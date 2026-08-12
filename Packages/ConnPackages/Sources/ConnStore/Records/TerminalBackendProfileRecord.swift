import ConnKit
import GRDB

struct TerminalBackendProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "terminal_backend_profile"

    var uuid: String
    var hostUUID: String
    var providerID: String
    var providerConfigurationKey: String
    var displayName: String
    var isEnabled: Bool
    var isPrimary: Bool
    var configurationVersion: Int
    var configurationJSON: String
    var sortOrder: Int
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool

    enum CodingKeys: String, CodingKey {
        case uuid
        case hostUUID = "host_uuid"
        case providerID = "provider_id"
        case providerConfigurationKey = "provider_configuration_key"
        case displayName = "display_name"
        case isEnabled = "is_enabled"
        case isPrimary = "is_primary"
        case configurationVersion = "configuration_version"
        case configurationJSON = "configuration_json"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
    }
}

extension TerminalBackendProfileRecord {
    init(_ profile: TerminalBackendProfile) {
        uuid = profile.id
        hostUUID = profile.hostID
        providerID = profile.providerID
        providerConfigurationKey = profile.providerConfigurationKey
        displayName = profile.displayName
        isEnabled = profile.isEnabled
        isPrimary = profile.isPrimary
        configurationVersion = profile.configurationVersion
        configurationJSON = profile.configurationJSON
        sortOrder = profile.sortOrder
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        syncDirty = profile.syncDirty
    }

    var identity: TerminalBackendProfile.Identity {
        TerminalBackendProfile.Identity(
            profileID: uuid,
            hostID: hostUUID,
            providerID: providerID,
            providerConfigurationKey: providerConfigurationKey
        )
    }

    func toDomain() -> TerminalBackendProfile {
        TerminalBackendProfile(
            id: uuid,
            hostID: hostUUID,
            providerID: providerID,
            providerConfigurationKey: providerConfigurationKey,
            displayName: displayName,
            isEnabled: isEnabled,
            isPrimary: isPrimary,
            configurationVersion: configurationVersion,
            configurationJSON: configurationJSON,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }
}
