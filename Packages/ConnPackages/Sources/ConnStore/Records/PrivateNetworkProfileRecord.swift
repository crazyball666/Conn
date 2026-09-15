import ConnKit
import Foundation
import GRDB

struct PrivateNetworkProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "private_network_profile"

    var uuid: String
    var name: String
    var provider: String
    var controlURL: String
    var authKeyRef: String
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool

    enum CodingKeys: String, CodingKey {
        case uuid, name, provider
        case controlURL = "control_url"
        case authKeyRef = "auth_key_ref"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
    }

    init(_ profile: PrivateNetworkProfile) {
        uuid = profile.id
        name = profile.name
        provider = profile.provider.rawValue
        controlURL = profile.controlURL
        authKeyRef = profile.authKeyRef
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        syncDirty = profile.syncDirty
    }

    func toDomain() throws -> PrivateNetworkProfile {
        guard let provider = PrivateNetworkProfile.Provider(rawValue: provider) else {
            throw PrivateNetworkProfileStoreError.unknownProvider(rawValue: provider)
        }
        return PrivateNetworkProfile(
            id: uuid,
            name: name,
            provider: provider,
            controlURL: controlURL,
            authKeyRef: authKeyRef,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }
}
