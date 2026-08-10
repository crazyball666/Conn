import GRDB

enum SchemaV3 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_builtin_snippet_group_keys") { db in
            try db.execute(sql: "ALTER TABLE snippet_group ADD COLUMN builtin_key TEXT")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_snippet_group_builtin_key
                ON snippet_group (builtin_key)
                WHERE builtin_key IS NOT NULL
                """)
        }
    }
}
