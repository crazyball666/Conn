import ConnKit
import Foundation
import GRDB
import Testing
@testable import ConnStore

@Suite("GRDB Schema v2 — 平台片段目录")
struct SchemaV2Tests {
    @Test("v1 旧片段迁移后默认适用于全部平台")
    func migratesLegacySnippetMetadata() throws {
        let queue = try DatabaseQueue()
        var v1 = DatabaseMigrator()
        SchemaV1.register(in: &v1)
        try v1.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO snippet
                    (uuid, title, script, interpreter, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["legacy", "旧片段", "uptime", "sh", 1, 1]
            )
            try db.execute(
                sql: """
                INSERT INTO snippet_group
                    (uuid, name, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: ["legacy-group", "System", 1, 1]
            )
        }

        var upgraded = DatabaseMigrator()
        SchemaV1.register(in: &upgraded)
        SchemaV2.register(in: &upgraded)
        SchemaV3.register(in: &upgraded)
        try upgraded.migrate(queue)
        let store = try SnippetStore(database: AppDatabase(queue))
        let loaded = try store.snippet(id: "legacy")
        let snippet = try #require(loaded)

        #expect(snippet.platforms.isEmpty)
        #expect(snippet.requiredCapabilities.isEmpty)
        #expect(snippet.builtinKey == nil)

        let legacyGroupKey: String? = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT builtin_key FROM snippet_group WHERE uuid = ?",
                arguments: ["legacy-group"]
            )?["builtin_key"]
        }
        #expect(legacyGroupKey == nil)
    }

    @Test("内置 key 唯一且删除后写入 suppression")
    func enforcesKeyAndSuppressesDeletedBuiltin() throws {
        let database = try AppDatabase.inMemory()
        let store = SnippetStore(database: database)
        let snippet = Snippet(
            title: "系统概览",
            script: "uname -a",
            platforms: [.linux],
            builtinKey: "system-overview-linux"
        )
        try store.save(snippet)

        try store.delete(id: snippet.id)

        #expect(try store.isBuiltinSuppressed("system-overview-linux"))
        #expect(try store.snippet(builtinKey: "system-overview-linux") == nil)
    }

    @Test("目录版本持久化")
    func persistsCatalogVersion() throws {
        let store = try SnippetStore(database: .inMemory())

        #expect(try store.builtinCatalogVersion() == 0)
        try store.setBuiltinCatalogVersion(2)
        #expect(try store.builtinCatalogVersion() == 2)
    }

    @Test("内置分组 key 持久化且唯一")
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
}
