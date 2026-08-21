import ConnMultiplexer
import Foundation
import GRDB

enum PersistentTerminalResumeStoreError: Error, Equatable {
    case descriptorIdentityMismatch(recordID: String)
}

struct PersistentTerminalResumeRecordRow:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable {
    static let databaseTableName = "persistent_terminal_resume_record"

    var uuid: String
    var hostUUID: String
    var providerID: String
    var providerConfigurationKey: String
    var workspaceID: String
    var descriptorJSON: Data
    var hostName: String
    var hostAddress: String
    var automaticAlias: String
    var alias: String?
    var createdAt: Int64
    var lastConnectedAt: Int64

    enum CodingKeys: String, CodingKey {
        case uuid
        case hostUUID = "host_uuid"
        case providerID = "provider_id"
        case providerConfigurationKey = "provider_configuration_key"
        case workspaceID = "workspace_id"
        case descriptorJSON = "descriptor_json"
        case hostName = "host_name"
        case hostAddress = "host_address"
        case automaticAlias = "automatic_alias"
        case alias
        case createdAt = "created_at"
        case lastConnectedAt = "last_connected_at"
    }

    init(_ record: PersistentTerminalResumeRecord) throws {
        uuid = record.id
        hostUUID = record.hostID
        providerID = record.providerID
        providerConfigurationKey = record.descriptor.configurationKey
        workspaceID = record.workspaceID
        descriptorJSON = try JSONEncoder().encode(record.descriptor)
        hostName = record.hostName
        hostAddress = record.hostAddress
        automaticAlias = record.automaticAlias
        alias = record.alias
        createdAt = Self.milliseconds(record.createdAt)
        lastConnectedAt = Self.milliseconds(record.lastConnectedAt)
    }

    func toDomain() throws -> PersistentTerminalResumeRecord {
        let descriptor = try JSONDecoder().decode(
            PersistentAttachmentDescriptor.self,
            from: descriptorJSON
        )
        guard descriptor.providerID == providerID,
              descriptor.configurationKey == providerConfigurationKey,
              descriptor.workspace.workspaceID == workspaceID
        else {
            throw PersistentTerminalResumeStoreError.descriptorIdentityMismatch(recordID: uuid)
        }
        return PersistentTerminalResumeRecord(
            id: uuid,
            hostID: hostUUID,
            hostName: hostName,
            hostAddress: hostAddress,
            descriptor: descriptor,
            automaticAlias: automaticAlias,
            alias: alias,
            createdAt: Self.date(createdAt),
            lastConnectedAt: Self.date(lastConnectedAt)
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
