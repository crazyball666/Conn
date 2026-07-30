import ConnKit
import Foundation
import GRDB
import Testing
@testable import ConnStore

/// 见 `HostRecord.swift` 中的说明：macOS Foundation 的已废弃 `NSHost`
/// 与领域模型 `Host` 同名，host 端跑测试时需显式消歧。
private typealias DomainHost = ConnKit.Host

@Suite("GRDB Schema v1")
struct SchemaV1Tests {
    @Test("迁移后全部表建成")
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
            "host", "host_group", "host_group_membership", "known_host",
            "run_history", "snippet", "snippet_group",
            "snippet_group_membership", "ssh_key"
        ])
    }

    @Test("初始 schema 的 run_history 包含状态列及已知默认值")
    func initialSchemaIncludesRunHistoryState() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        SchemaV1.register(in: &migrator)
        try migrator.migrate(queue)

        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO run_history (uuid, host_uuid, command, ran_at) VALUES (?, ?, ?, ?)",
                arguments: ["run-1", "host-1", "uptime", 1000]
            )
        }

        let state = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM run_history WHERE uuid = ?", arguments: ["run-1"])
        }
        #expect(state == RunHistoryState.known.rawValue)
    }

    @Test("迁移可重复执行且幂等")
    func migrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        let second = try AppDatabase(queue) // 同一 writer 再跑一次迁移
        let count = try second.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM host") }
        #expect(count == 0)
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
        #expect(loaded?.toDomain() == host)
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
