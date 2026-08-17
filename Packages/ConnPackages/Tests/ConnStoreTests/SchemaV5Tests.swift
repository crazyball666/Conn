import GRDB
import Testing
@testable import ConnStore

@Suite("GRDB Schema v5 — remove terminal backend profiles")
struct SchemaV5Tests {
    @Test("v5 在旧配置表已经不存在时仍可安全执行")
    func toleratesAlreadyMissingObsoleteTable() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        SchemaV5.register(in: &migrator)

        try migrator.migrate(queue)

        let exists = try queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
                arguments: ["terminal_backend_profile"]
            )
        }
        #expect(exists == false)
    }

    @Test("v5 删除废弃配置表但保留已有主机")
    func dropsObsoleteTableWithoutLosingHosts() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        SchemaV1.register(in: &migrator)
        SchemaV2.register(in: &migrator)
        SchemaV3.register(in: &migrator)
        SchemaV4.register(in: &migrator)
        try migrator.migrate(queue)

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO ssh_key (uuid, name, kind, public_key, private_ref, created_at, updated_at)
                VALUES ('key-1', 'Test key', 'ed25519', 'ssh-ed25519 AAAA', 'keychain-ref', 1, 1)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO host_group (uuid, name, created_at, updated_at)
                VALUES ('group-1', 'Production', 1, 1)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO host (
                    uuid, name, address, username, auth_kind, key_uuid, created_at, updated_at
                ) VALUES ('host-1', 'Test', 'test.local', 'tester', 'key', 'key-1', 1, 1)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO host_group_membership (host_uuid, group_uuid)
                VALUES ('host-1', 'group-1')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO terminal_backend_profile (
                    uuid, host_uuid, provider_id, provider_configuration_key, display_name,
                    configuration_version, configuration_json, created_at, updated_at
                ) VALUES ('old-profile', 'host-1', 'tmux', 'default', 'tmux', 1, '{}', 1, 1)
                """
            )
        }

        SchemaV5.register(in: &migrator)
        try migrator.migrate(queue)

        let result = try queue.read { db in
            let hosts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host") ?? -1
            let keys = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ssh_key") ?? -1
            let groups = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host_group") ?? -1
            let memberships = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM host_group_membership"
            ) ?? -1
            let obsoleteTableExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
                arguments: ["terminal_backend_profile"]
            ) ?? true
            return (hosts, keys, groups, memberships, obsoleteTableExists)
        }
        #expect(result.0 == 1)
        #expect(result.1 == 1)
        #expect(result.2 == 1)
        #expect(result.3 == 1)
        #expect(result.4 == false)
    }

    @Test("AppDatabase 当前 schema 不再包含终端 provider 配置表")
    func currentSchemaDoesNotContainObsoleteTable() throws {
        let database = try AppDatabase.inMemory()
        let exists = try database.writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
                arguments: ["terminal_backend_profile"]
            )
        }
        #expect(exists == false)
    }
}
