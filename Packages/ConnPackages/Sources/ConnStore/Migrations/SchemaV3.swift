import GRDB

enum SchemaV3 {
    /// 命令支持多分组，并为分组增加稳定的显示顺序。
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_snippet_multi_folder_and_order") { db in
            try db.alter(table: "snippet_folder") { table in
                table.add(column: "sort_order", .integer).notNull().defaults(to: 0)
            }

            let existingFolders = try String.fetchAll(
                db,
                sql: "SELECT name FROM snippet_folder ORDER BY name COLLATE NOCASE"
            )
            for (index, name) in existingFolders.enumerated() {
                try db.execute(
                    sql: "UPDATE snippet_folder SET sort_order = ? WHERE name = ?",
                    arguments: [index, name]
                )
            }

            let legacyFolders = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT TRIM(folder)
                FROM snippet
                WHERE folder IS NOT NULL AND TRIM(folder) <> ''
                GROUP BY TRIM(folder)
                ORDER BY MIN(sort_order), MIN(created_at), 1 COLLATE NOCASE
                """
            )
            var nextOrder = existingFolders.count
            for name in legacyFolders where !existingFolders.contains(name) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO snippet_folder (name, sort_order) VALUES (?, ?)",
                    arguments: [name, nextOrder]
                )
                nextOrder += 1
            }

            try db.create(table: "snippet_folder_membership") { table in
                table.column("snippet_uuid", .text)
                    .notNull()
                    .references("snippet", column: "uuid", onDelete: .cascade)
                table.column("folder_name", .text)
                    .notNull()
                    .references("snippet_folder", column: "name", onDelete: .cascade)
                table.primaryKey(["snippet_uuid", "folder_name"])
            }

            try db.execute(sql: """
                INSERT OR IGNORE INTO snippet_folder_membership (snippet_uuid, folder_name)
                SELECT uuid, TRIM(folder)
                FROM snippet
                WHERE folder IS NOT NULL AND TRIM(folder) <> ''
                """)
        }
    }
}
