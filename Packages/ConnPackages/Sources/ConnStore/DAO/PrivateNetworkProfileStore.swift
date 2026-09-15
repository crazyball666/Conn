import ConnKit
import Foundation
import GRDB

public enum PrivateNetworkProfileStoreError: Error, Equatable {
    case unknownProvider(rawValue: String)
    case invalidProfile(PrivateNetworkProfile.ValidationError)
    case profileInUse(profileID: String)
}

/// `private_network_profile` 的读写入口。
public struct PrivateNetworkProfileStore: PrivateNetworkProfileRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allProfiles() throws -> [PrivateNetworkProfile] {
        try database.writer.read { db in
            try PrivateNetworkProfileRecord
                .order(sql: "name COLLATE NOCASE ASC")
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func profile(id: String) throws -> PrivateNetworkProfile? {
        try database.writer.read { db in
            try PrivateNetworkProfileRecord.fetchOne(db, key: id).map { try $0.toDomain() }
        }
    }

    public func save(_ profile: PrivateNetworkProfile) throws {
        if let error = profile.validationError {
            throw PrivateNetworkProfileStoreError.invalidProfile(error)
        }
        var updated = profile
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try PrivateNetworkProfileRecord(updated).save($0) }
    }

    public func delete(id: String) throws {
        try database.writer.write { db in
            let inUse = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM host WHERE private_network_profile_uuid = ?)",
                arguments: [id]
            ) ?? false
            guard !inUse else {
                throw PrivateNetworkProfileStoreError.profileInUse(profileID: id)
            }
            try db.execute(sql: "DELETE FROM private_network_profile WHERE uuid = ?", arguments: [id])
        }
    }
}
