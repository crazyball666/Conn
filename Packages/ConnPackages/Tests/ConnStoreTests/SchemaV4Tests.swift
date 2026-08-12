import GRDB
import Testing
@testable import ConnStore

@Suite("GRDB Schema v4 — terminal backend profiles")
struct SchemaV4Tests {
    @Test("v4 建立精确字段、类型与默认值")
    func createsExactColumns() throws {
        let queue = try migratedQueue()

        let columns = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(terminal_backend_profile)").map {
                SchemaColumn(
                    name: $0["name"],
                    type: $0["type"],
                    isNotNull: ($0["notnull"] as Int) == 1,
                    defaultValue: $0["dflt_value"],
                    primaryKeyOrder: $0["pk"]
                )
            }
        }

        #expect(columns == [
            .init(name: "uuid", type: "TEXT", isNotNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "host_uuid", type: "TEXT", isNotNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "provider_id", type: "TEXT", isNotNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(
                name: "provider_configuration_key",
                type: "TEXT",
                isNotNull: true,
                defaultValue: nil,
                primaryKeyOrder: 0
            ),
            .init(name: "display_name", type: "TEXT", isNotNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "is_enabled", type: "INTEGER", isNotNull: true, defaultValue: "1", primaryKeyOrder: 0),
            .init(name: "is_primary", type: "INTEGER", isNotNull: true, defaultValue: "0", primaryKeyOrder: 0),
            .init(
                name: "configuration_version",
                type: "INTEGER",
                isNotNull: true,
                defaultValue: nil,
                primaryKeyOrder: 0
            ),
            .init(
                name: "configuration_json",
                type: "TEXT",
                isNotNull: true,
                defaultValue: nil,
                primaryKeyOrder: 0
            ),
            .init(name: "sort_order", type: "INTEGER", isNotNull: true, defaultValue: "0", primaryKeyOrder: 0),
            .init(name: "created_at", type: "INTEGER", isNotNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "updated_at", type: "INTEGER", isNotNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "sync_dirty", type: "INTEGER", isNotNull: true, defaultValue: "0", primaryKeyOrder: 0),
        ])
    }

    @Test("v4 外键和两个唯一索引具有精确作用域")
    func createsForeignKeyAndUniqueIndexes() throws {
        let queue = try migratedQueue()

        let foreignKeys = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(terminal_backend_profile)").map {
                ForeignKeyDefinition(
                    table: $0["table"],
                    from: $0["from"],
                    to: $0["to"],
                    onDelete: $0["on_delete"]
                )
            }
        }
        #expect(foreignKeys == [
            .init(table: "host", from: "host_uuid", to: "uuid", onDelete: "CASCADE"),
        ])

        let indexes = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(terminal_backend_profile)")
                .filter { ($0["origin"] as String) == "c" }
                .map {
                    SchemaIndex(
                        name: $0["name"],
                        isUnique: ($0["unique"] as Int) == 1,
                        isPartial: ($0["partial"] as Int) == 1
                    )
                }
                .sorted { $0.name < $1.name }
        }
        #expect(indexes == [
            .init(name: "idx_terminal_backend_profile_identity", isUnique: true, isPartial: false),
            .init(name: "idx_terminal_backend_profile_primary", isUnique: true, isPartial: true),
        ])

        let identityColumns = try indexColumns("idx_terminal_backend_profile_identity", in: queue)
        let primaryColumns = try indexColumns("idx_terminal_backend_profile_primary", in: queue)
        #expect(identityColumns == ["host_uuid", "provider_id", "provider_configuration_key"])
        #expect(primaryColumns == ["host_uuid", "provider_id"])

        let primarySQL = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
                arguments: ["idx_terminal_backend_profile_primary"]
            )
        }
        #expect(primarySQL?.uppercased().contains("WHERE IS_PRIMARY = 1") == true)
    }

    @Test("profile 身份与 primary 唯一且删除 host 会级联清理")
    func enforcesIdentityPrimaryAndCascade() throws {
        let queue = try migratedQueue()
        try insertHost(id: "host-1", in: queue)
        try insertProfile(id: "profile-1", key: "default", isPrimary: true, in: queue)

        #expect(throws: DatabaseError.self) {
            try insertProfile(id: "duplicate-identity", key: "default", in: queue)
        }
        #expect(throws: DatabaseError.self) {
            try insertProfile(id: "duplicate-primary", key: "named:ops", isPrimary: true, in: queue)
        }

        try insertProfile(id: "profile-2", key: "named:ops", providerID: "future", isPrimary: true, in: queue)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM host WHERE uuid = ?", arguments: ["host-1"])
        }
        let remaining = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM terminal_backend_profile") ?? -1
        }
        #expect(remaining == 0)
    }

    @Test("AppDatabase 正式迁移链包含 v4")
    func appDatabaseRegistersV4() throws {
        let database = try AppDatabase.inMemory()
        let exists = try database.writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
                arguments: ["terminal_backend_profile"]
            )
        }
        #expect(exists == true)
    }
}

private struct SchemaColumn: Equatable {
    let name: String
    let type: String
    let isNotNull: Bool
    let defaultValue: String?
    let primaryKeyOrder: Int
}

private struct ForeignKeyDefinition: Equatable {
    let table: String
    let from: String
    let to: String
    let onDelete: String
}

private struct SchemaIndex: Equatable {
    let name: String
    let isUnique: Bool
    let isPartial: Bool
}

private func migratedQueue() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    var migrator = DatabaseMigrator()
    SchemaV1.register(in: &migrator)
    SchemaV2.register(in: &migrator)
    SchemaV3.register(in: &migrator)
    SchemaV4.register(in: &migrator)
    try migrator.migrate(queue)
    return queue
}

private func indexColumns(_ index: String, in queue: DatabaseQueue) throws -> [String] {
    try queue.read { db in
        try Row.fetchAll(db, sql: "PRAGMA index_info(\(index))")
            .sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
            .map { $0["name"] as String }
    }
}

private func insertHost(id: String, in queue: DatabaseQueue) throws {
    try queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO host (uuid, name, address, username, auth_kind, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, "Test", "test.local", "tester", "key", 1, 1]
        )
    }
}

private func insertProfile(
    id: String,
    key: String,
    providerID: String = "tmux",
    isPrimary: Bool = false,
    in queue: DatabaseQueue
) throws {
    try queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO terminal_backend_profile (
                uuid, host_uuid, provider_id, provider_configuration_key, display_name,
                is_primary, configuration_version, configuration_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, "host-1", providerID, key, key, isPrimary, 1, "{}", 1, 1]
        )
    }
}
