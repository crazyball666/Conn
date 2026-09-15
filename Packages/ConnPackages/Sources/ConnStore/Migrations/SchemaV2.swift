import GRDB

/// Tailscale/Headscale profile and per-host connection-route configuration.
enum SchemaV2 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_host_connection_routes") { db in
            // v1.0.1 has neither this table nor these host columns. A short-lived
            // feature build modified v1 in place, however, so tolerate databases
            // where some or all of the v2 shape is already present.
            if try !db.tableExists("private_network_profile") {
                try db.create(table: "private_network_profile") { t in
                    t.primaryKey("uuid", .text)
                    t.column("name", .text).notNull()
                    t.column("provider", .text).notNull()
                    t.column("control_url", .text).notNull()
                    // Keychain reference only; auth key plaintext never enters SQLite.
                    t.column("auth_key_ref", .text).notNull()
                    t.column("created_at", .integer).notNull()
                    t.column("updated_at", .integer).notNull()
                    t.column("sync_dirty", .integer).notNull().defaults(to: 0)
                }
            }

            let hostColumns = Set(try db.columns(in: "host").map(\.name))
            if !hostColumns.contains("private_network_profile_uuid") {
                // Nullable by design: all existing hosts remain ordinary direct connections.
                try db.execute(sql: """
                    ALTER TABLE host
                    ADD COLUMN private_network_profile_uuid TEXT
                    REFERENCES private_network_profile(uuid) ON DELETE RESTRICT
                    """)
            }
            if !hostColumns.contains("proxy_configuration") {
                try db.execute(sql: "ALTER TABLE host ADD COLUMN proxy_configuration TEXT")
            }
        }
    }
}
