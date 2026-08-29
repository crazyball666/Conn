import ConnKit
import Foundation
import GRDB
import Testing
@testable import ConnStore

/// 见 `HostRecord.swift` 中的说明：macOS Foundation 的已废弃 `NSHost`
/// 与领域模型 `Host` 同名，host 端跑测试时需显式消歧。
private typealias DomainHost = ConnKit.Host

@Suite("GRDB 当前完整 Schema")
struct SchemaV1Tests {
    @Test("建库后全部表一次性创建")
    func createsAllTables() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.writer.read { database in
            try String.fetchAll(database, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            ORDER BY name
            """)
        }
        #expect(tables == [
            "builtin_snippet_catalog_state", "builtin_snippet_suppression",
            "host", "host_group", "host_group_membership", "known_host",
            "persistent_terminal_resume_record", "run_history", "snippet", "snippet_group",
            "snippet_group_membership", "ssh_key"
        ])
    }

    @Test("建库只记录一份完整 Schema")
    func registersSingleSchema() throws {
        let database = try AppDatabase.inMemory()
        let identifiers = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(identifiers == ["v1_initial_schema"])
    }

    @Test("初始 schema 的 run_history 包含状态列及已知默认值")
    func initialSchemaIncludesRunHistoryState() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        SchemaV1.register(in: &migrator)
        try migrator.migrate(queue)

        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO run_history (uuid, host_uuid, script, ran_at) VALUES (?, ?, ?, ?)",
                arguments: ["run-1", "host-1", "uptime", 1000]
            )
        }

        let state = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM run_history WHERE uuid = ?", arguments: ["run-1"])
        }
        #expect(state == RunHistoryState.known.rawValue)
    }

    @Test("建库可重复执行且幂等")
    func schemaInitializationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        let second = try AppDatabase(queue) // 同一 writer 再跑一次迁移
        let count = try second.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM host") }
        #expect(count == 0)
    }

    @Test("片段目录字段和默认状态由初始 Schema 直接创建")
    func initialSchemaIncludesSnippetCatalogMetadata() throws {
        let database = try AppDatabase.inMemory()
        let store = SnippetStore(database: database)
        let snippet = Snippet(title: "Uptime", script: "uptime")
        try store.save(snippet)

        let loaded = try #require(try store.snippet(id: snippet.id))
        #expect(loaded.requiredCapabilities.isEmpty)
        #expect(loaded.builtinKey == nil)
        #expect(try store.builtinCatalogVersion() == 0)
    }

    @Test("内置片段 key 唯一且删除后写入 suppression")
    func enforcesKeyAndSuppressesDeletedBuiltin() throws {
        let database = try AppDatabase.inMemory()
        let store = SnippetStore(database: database)
        let snippet = Snippet(
            title: "系统概览",
            script: "uname -a",
            builtinKey: "system-overview-linux"
        )
        try store.save(snippet)

        try store.delete(id: snippet.id)

        #expect(try store.isBuiltinSuppressed("system-overview-linux"))
        #expect(try store.snippet(builtinKey: "system-overview-linux") == nil)
    }

    @Test("内置目录版本可持久化")
    func persistsCatalogVersion() throws {
        let store = try SnippetStore(database: .inMemory())

        #expect(try store.builtinCatalogVersion() == 0)
        try store.setBuiltinCatalogVersion(2)
        #expect(try store.builtinCatalogVersion() == 2)
    }

    @Test("内置分组 key 可持久化且唯一")
    func persistsUniqueBuiltinGroupKey() throws {
        let database = try AppDatabase.inMemory()
        let groups = SnippetGroupStore(database: database)
        try groups.save(SnippetGroup(name: "系统", builtinKey: "system"))

        let loaded = try #require(groups.allGroups().first)
        #expect(loaded.builtinKey == "system")
        #expect(throws: (any Error).self) {
            try groups.save(SnippetGroup(name: "另一个系统", builtinKey: "system"))
        }
    }

    @Test("完整 Schema 不包含已废弃的终端配置表")
    func doesNotContainObsoleteTerminalProfileTable() throws {
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

    @Test("host 表可写入并读回，字段无损")
    func hostRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let host = DomainHost(
            name: "web-01",
            address: "10.0.0.1",
            username: "root",
            port: 2222,
            jumpChain: ["bastion-uuid"],
            tags: ["prod", "web"]
        )
        try db.writer.write { try HostRecord(host).insert($0) }

        let loaded = try db.writer.read { try HostRecord.fetchOne($0, key: host.id) }
        let loadedDomain = try loaded?.toDomain()
        #expect(loadedDomain == host)
    }

    @Test("jump_chain 与 tags 以 JSON 存储，可正确往返")
    func jsonColumnsRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let host = DomainHost(name: "a", address: "1", username: "r", jumpChain: ["x", "y"], tags: ["p"])
        try db.writer.write { try HostRecord(host).insert($0) }

        let raw = try db.writer.read { database in
            try Row.fetchOne(database, sql: "SELECT jump_chain, tags FROM host")
        }
        #expect(raw?["jump_chain"] == #"["x","y"]"#)
        #expect(raw?["tags"] == #"["p"]"#)
    }

    @Test("外键约束开启：成员行指向不存在的分组时拒绝写入")
    func enforcesForeignKeys() throws {
        let db = try AppDatabase.inMemory()
        let host = DomainHost(name: "a", address: "1", username: "r")
        try db.writer.write { try HostRecord(host).insert($0) }

        #expect(throws: DatabaseError.self) {
            try db.writer.write { database in
                try database.execute(
                    sql: "INSERT INTO host_group_membership (host_uuid, group_uuid) VALUES (?, ?)",
                    arguments: [host.id, "not-exist"]
                )
            }
        }
    }
}
