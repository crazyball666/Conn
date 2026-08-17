import GRDB

enum SchemaV5 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5_remove_terminal_backend_profiles") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS terminal_backend_profile")
        }
    }
}
