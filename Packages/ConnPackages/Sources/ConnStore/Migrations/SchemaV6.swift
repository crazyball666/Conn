import GRDB

enum SchemaV6 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6_persistent_terminal_resume_records") { db in
            try db.create(table: "persistent_terminal_resume_record") { table in
                table.primaryKey("uuid", .text)
                table.column("host_uuid", .text)
                    .notNull()
                    .references("host", column: "uuid", onDelete: .cascade)
                table.column("provider_id", .text).notNull()
                table.column("provider_configuration_key", .text).notNull()
                table.column("workspace_id", .text).notNull()
                table.column("descriptor_json", .blob).notNull()
                table.column("host_name", .text).notNull()
                table.column("host_address", .text).notNull()
                table.column("automatic_alias", .text).notNull()
                table.column("alias", .text)
                table.column("created_at", .integer).notNull()
                table.column("last_connected_at", .integer).notNull()
            }
            try db.create(
                index: "idx_persistent_terminal_resume_identity",
                on: "persistent_terminal_resume_record",
                columns: [
                    "host_uuid",
                    "provider_id",
                    "provider_configuration_key",
                    "workspace_id"
                ],
                unique: true
            )
            try db.create(
                index: "idx_persistent_terminal_resume_recent",
                on: "persistent_terminal_resume_record",
                columns: ["last_connected_at"]
            )
        }
    }
}
