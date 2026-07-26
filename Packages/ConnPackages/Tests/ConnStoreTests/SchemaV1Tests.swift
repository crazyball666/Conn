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
            "app_setting", "host", "host_group", "known_host",
            "metric_sample", "probe_target", "run_history", "snippet",
            "snippet_folder", "snippet_folder_membership", "ssh_key"
        ])
    }

    @Test("迁移可重复执行且幂等")
    func migrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        let second = try AppDatabase(queue) // 同一 writer 再跑一次迁移
        let count = try second.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM host") }
        #expect(count == 0)
    }

    @Test("旧版单分组数据迁移为多分组关联，并保留首次出现顺序")
    func migratesLegacySnippetFolders() throws {
        let queue = try DatabaseQueue()
        var legacyMigrator = DatabaseMigrator()
        SchemaV1.register(in: &legacyMigrator)
        SchemaV2.register(in: &legacyMigrator)
        try legacyMigrator.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO snippet
                (uuid, title, command, folder, sort_order, created_at, updated_at)
                VALUES
                ('a', '系统', 'a', '系统', 0, 1, 1),
                ('b', '日志', 'b', '日志', 1, 2, 2)
                """
            )
        }

        let database = try AppDatabase(queue)
        let store = SnippetStore(database: database)

        #expect(try store.allFolders() == ["系统", "日志"])
        #expect(try store.snippet(id: "a")?.folders == ["系统"])
        #expect(try store.snippet(id: "b")?.folders == ["日志"])
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

    @Test("metric_sample 主键为 (host_uuid, ts)，重复插入冲突")
    func metricSampleCompositeKey() throws {
        let db = try AppDatabase.inMemory()
        let sql = """
        INSERT INTO metric_sample
        (host_uuid, ts, cpu, mem, load1, disk_used, disk_total, net_rx, net_tx)
        VALUES (?,?,?,?,?,?,?,?,?)
        """
        try db.writer.write { database in
            try database.execute(sql: sql, arguments: ["h1", 1000, 10.0, 20.0, 0.5, 100, 200, 0, 0])
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { database in
                try database.execute(sql: sql, arguments: ["h1", 1000, 99.0, 20.0, 0.5, 100, 200, 0, 0])
            }
        }
    }

    @Test("外键约束开启：group_uuid 指向不存在的分组时拒绝写入")
    func enforcesForeignKeys() throws {
        let db = try AppDatabase.inMemory()
        let host = DomainHost(name: "a", address: "1", username: "r", groupUUID: "not-exist")
        #expect(throws: DatabaseError.self) {
            try db.writer.write { try HostRecord(host).insert($0) }
        }
    }
}
