import GRDB

enum SchemaV2 {
    /// 命令分组需要独立于片段存在，才能先建分组、再从表单中选择。
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_snippet_folder") { db in
            try db.create(table: "snippet_folder") { table in
                table.primaryKey("name", .text)
            }
        }
    }
}
