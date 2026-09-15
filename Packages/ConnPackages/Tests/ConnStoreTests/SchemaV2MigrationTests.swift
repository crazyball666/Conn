import ConnKit
import Foundation
import GRDB
import Testing
@testable import ConnStore

@Suite("已发版 v1 数据库升级")
struct SchemaV2MigrationTests {
    @Test("升级保留旧主机并创建私有网络配置结构")
    func migratesReleasedV1DatabaseWithoutLosingHosts() throws {
        let writer = try makeReleasedV1Database()
        try insertLegacyHost(into: writer)

        let database = try AppDatabase(writer)
        let host = try #require(try HostStore(database: database).host(id: "legacy-host"))
        let profiles = try PrivateNetworkProfileStore(database: database).allProfiles()
        let migrationIDs = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        let hostColumns = try database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(host)")
        }
        let hostForeignKeys = try database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(host)")
        }

        #expect(host.name == "生产主机")
        #expect(host.address == "10.0.0.8")
        #expect(host.port == 2222)
        #expect(host.privateNetworkProfileID == nil)
        #expect(host.proxyConfiguration == nil)
        #expect(profiles.isEmpty)
        #expect(migrationIDs == ["v1_initial_schema", "v2_host_connection_routes"])
        #expect(hostColumns.contains { $0["name"] as String? == "private_network_profile_uuid" })
        #expect(hostColumns.contains { $0["name"] as String? == "proxy_configuration" })
        #expect(hostForeignKeys.contains {
            $0["table"] as String? == "private_network_profile"
                && $0["from"] as String? == "private_network_profile_uuid"
        })
    }

    @Test("兼容此前已扩展 v1 的数据库并保留已有私有网络配置")
    func migratesDatabaseCreatedByFeatureBuild() throws {
        let writer = try makeReleasedV1Database()
        try insertLegacyHost(into: writer)
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE private_network_profile (
                    uuid TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    control_url TEXT NOT NULL,
                    auth_key_ref TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    sync_dirty INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                ALTER TABLE host ADD COLUMN private_network_profile_uuid TEXT
                REFERENCES private_network_profile(uuid) ON DELETE RESTRICT
                """)
            try db.execute(sql: "ALTER TABLE host ADD COLUMN proxy_configuration TEXT")
            try db.execute(
                sql: """
                INSERT INTO private_network_profile
                    (uuid, name, provider, control_url, auth_key_ref, created_at, updated_at, sync_dirty)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "tailnet-1", "Office", "tailscale",
                    "https://controlplane.tailscale.com", "key-ref", 1_000, 1_000, 0
                ]
            )
            try db.execute(
                sql: "UPDATE host SET private_network_profile_uuid = ? WHERE uuid = ?",
                arguments: ["tailnet-1", "legacy-host"]
            )
        }

        let database = try AppDatabase(writer)
        let host = try #require(try HostStore(database: database).host(id: "legacy-host"))
        let profile = try #require(
            try PrivateNetworkProfileStore(database: database).profile(id: "tailnet-1")
        )
        let migrationIDs = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }

        #expect(host.privateNetworkProfileID == "tailnet-1")
        #expect(profile.name == "Office")
        #expect(migrationIDs == ["v1_initial_schema", "v2_host_connection_routes"])
    }

    private func insertLegacyHost(into writer: DatabaseQueue) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO host (
                    uuid, name, address, port, username, auth_kind,
                    credential_ref, key_uuid, jump_chain, tags, icon, color,
                    note, expire_at, sort_order, status, created_at, updated_at, sync_dirty
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "legacy-host", "生产主机", "10.0.0.8", 2222, "root", "password",
                    nil, nil, "[]", "[]", nil, nil, nil, nil, 0, "unknown", 1_000, 1_000, 0
                ]
            )
        }
    }

    private func makeReleasedV1Database() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let writer = try DatabaseQueue(configuration: configuration)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "host_group") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "ssh_key") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("public_key", .text).notNull()
                t.column("private_ref", .text)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "host") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("address", .text).notNull()
                t.column("port", .integer).notNull().defaults(to: 22)
                t.column("username", .text).notNull()
                t.column("auth_kind", .text).notNull()
                t.column("credential_ref", .text)
                t.column("key_uuid", .text).references("ssh_key", column: "uuid", onDelete: .restrict)
                t.column("jump_chain", .text).notNull().defaults(to: "[]")
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("icon", .text)
                t.column("color", .text)
                t.column("note", .text)
                t.column("expire_at", .integer)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull().defaults(to: "unknown")
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "host_group_membership") { t in
                t.column("host_uuid", .text).notNull()
                    .references("host", column: "uuid", onDelete: .cascade)
                t.column("group_uuid", .text).notNull()
                    .references("host_group", column: "uuid", onDelete: .cascade)
                t.primaryKey(["host_uuid", "group_uuid"])
            }
        }
        try legacyMigrator.migrate(writer)
        return writer
    }
}
