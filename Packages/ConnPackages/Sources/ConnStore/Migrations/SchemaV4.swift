import GRDB

enum SchemaV4 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4_terminal_backend_profiles") { db in
            try db.create(table: "terminal_backend_profile") { table in
                table.primaryKey("uuid", .text)
                table.column("host_uuid", .text)
                    .notNull()
                    .references("host", column: "uuid", onDelete: .cascade)
                table.column("provider_id", .text).notNull()
                table.column("provider_configuration_key", .text).notNull()
                table.column("display_name", .text).notNull()
                table.column("is_enabled", .integer).notNull().defaults(to: 1)
                table.column("is_primary", .integer).notNull().defaults(to: 0)
                table.column("configuration_version", .integer).notNull()
                table.column("configuration_json", .text).notNull()
                table.column("sort_order", .integer).notNull().defaults(to: 0)
                table.column("created_at", .integer).notNull()
                table.column("updated_at", .integer).notNull()
                table.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }

            try db.create(
                index: "idx_terminal_backend_profile_identity",
                on: "terminal_backend_profile",
                columns: ["host_uuid", "provider_id", "provider_configuration_key"],
                unique: true
            )
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_terminal_backend_profile_primary
                ON terminal_backend_profile (host_uuid, provider_id)
                WHERE is_primary = 1
                """)
        }
    }
}
