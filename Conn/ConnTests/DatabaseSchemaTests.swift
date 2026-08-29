import ConnStore
import GRDB
import Testing

@Suite("Current database schema")
struct DatabaseSchemaTests {
    @Test("完整 Schema 在 iOS 中一次建成")
    func createsCompleteSchema() throws {
        let database = try AppDatabase.inMemory()
        let result = try database.writer.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
            let schemaIdentifiers = try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
            )
            return (tables, schemaIdentifiers)
        }

        #expect(result.0 == [
            "builtin_snippet_catalog_state", "builtin_snippet_suppression",
            "host", "host_group", "host_group_membership", "known_host",
            "persistent_terminal_resume_record", "run_history", "snippet", "snippet_group",
            "snippet_group_membership", "ssh_key"
        ])
        #expect(result.1 == ["v1_initial_schema"])
    }
}
