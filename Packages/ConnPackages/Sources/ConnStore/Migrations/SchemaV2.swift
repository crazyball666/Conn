import GRDB

enum SchemaV2 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_platform_snippet_catalog") { db in
            // 迁移名称为兼容已创建的开发数据库保留；脚本本身不声明目标平台。
            try db.execute(sql: "ALTER TABLE snippet ADD COLUMN required_capabilities_json TEXT")
            try db.execute(sql: "ALTER TABLE snippet ADD COLUMN builtin_key TEXT")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_snippet_builtin_key
                ON snippet (builtin_key)
                WHERE builtin_key IS NOT NULL
                """)

            try db.create(table: "builtin_snippet_catalog_state") { table in
                table.primaryKey("singleton", .integer)
                table.column("catalog_version", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                INSERT INTO builtin_snippet_catalog_state (singleton, catalog_version)
                VALUES (1, 0)
                """)

            try db.create(table: "builtin_snippet_suppression") { table in
                table.primaryKey("builtin_key", .text)
                table.column("suppressed_at", .integer).notNull()
            }
        }
    }
}
