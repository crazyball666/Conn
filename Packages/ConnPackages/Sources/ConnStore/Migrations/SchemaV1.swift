import ConnKit
import Foundation
import GRDB

enum SchemaV1 {
    /// 注册当前开发期的完整 Schema。
    ///
    /// 命名遵循技术实现方案 §3：蛇形字段名；所有实体表带 `uuid` 主键、
    /// `created_at`/`updated_at`（毫秒）与 `sync_dirty`。
    ///
    /// **有意偏离 §3 的一点：不设 `deleted_at` 墓碑，删除一律真 DELETE。**
    /// 墓碑的唯一收益是让 v1.1 同步能传播删除，代价是每个查询都得记得写
    /// `WHERE deleted_at IS NULL`（漏一次即数据泄漏）。删除传播留待 v1.1
    /// 立项时重新决策，详见 docs/superpowers/specs/2026-07-27-server-groups-design.md。
    ///
    /// 长度由表数量决定而非逻辑复杂度；开发阶段只维护这一份完整建库定义。
    static func register(in migrator: inout DatabaseMigrator) { // swiftlint:disable:this function_body_length
        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "host_group") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "ssh_key") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("public_key", .text).notNull()
                // Keychain 引用键，非私钥本身
                t.column("private_ref", .text)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "host") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("address", .text).notNull()
                t.column("port", .integer).notNull().defaults(to: 22)
                t.column("username", .text).notNull()
                t.column("auth_kind", .text).notNull()
                // Keychain 引用键，密文绝不入库（红线 §2）
                t.column("credential_ref", .text)
                t.column("key_uuid", .text).references("ssh_key", column: "uuid", onDelete: .restrict)
                t.column("jump_chain", .text).notNull().defaults(to: "[]") // JSON 数组
                t.column("tags", .text).notNull().defaults(to: "[]") // JSON 数组
                t.column("icon", .text)
                t.column("color", .text)
                t.column("note", .text)
                t.column("expire_at", .integer)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull().defaults(to: "unknown")
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }

            // 成员行是真删除（无墓碑）：它不是独立同步单元，只随父实体的 save
            // 被整体重写，§4.11 的冲突策略是 record 级 LWW。
            try db.create(table: "host_group_membership") { t in
                t.column("host_uuid", .text)
                    .notNull()
                    .references("host", column: "uuid", onDelete: .cascade)
                t.column("group_uuid", .text)
                    .notNull()
                    .references("host_group", column: "uuid", onDelete: .cascade)
                t.primaryKey(["host_uuid", "group_uuid"])
            }
            try db.create(
                index: "idx_host_group_membership_group",
                on: "host_group_membership",
                columns: ["group_uuid"]
            )

            try db.create(table: "known_host") { t in
                t.primaryKey("uuid", .text)
                t.column("host_pattern", .text).notNull()
                t.column("key_type", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("first_seen", .integer).notNull()
            }
            try db.create(
                index: "idx_known_host_pattern",
                on: "known_host",
                columns: ["host_pattern", "key_type"],
                unique: true
            )

            try db.create(table: "snippet") { t in
                t.primaryKey("uuid", .text)
                t.column("title", .text).notNull()
                t.column("script", .text).notNull()
                t.column("interpreter", .text).notNull().defaults(to: ShellInterpreter.sh.rawValue)
                t.column("required_capabilities_json", .text)
                t.column("builtin_key", .text)
                t.column("pinned", .integer).notNull().defaults(to: 0)
                t.column("danger", .integer).notNull().defaults(to: 0)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }
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

            try db.create(table: "snippet_group") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("builtin_key", .text)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_snippet_group_builtin_key
                ON snippet_group (builtin_key)
                WHERE builtin_key IS NOT NULL
                """)

            // 成员行是真删除（无墓碑）：它不是独立同步单元，只随父实体的 save
            // 被整体重写，§4.11 的冲突策略是 record 级 LWW。
            try db.create(table: "snippet_group_membership") { t in
                t.column("snippet_uuid", .text)
                    .notNull()
                    .references("snippet", column: "uuid", onDelete: .cascade)
                t.column("group_uuid", .text)
                    .notNull()
                    .references("snippet_group", column: "uuid", onDelete: .cascade)
                t.primaryKey(["snippet_uuid", "group_uuid"])
            }
            try db.create(
                index: "idx_snippet_group_membership_group",
                on: "snippet_group_membership",
                columns: ["group_uuid"]
            )

            try db.create(table: "run_history") { t in
                t.primaryKey("uuid", .text)
                t.column("host_uuid", .text).notNull()
                t.column("script", .text).notNull()
                t.column("interpreter", .text).notNull().defaults(to: ShellInterpreter.sh.rawValue)
                t.column("exit_code", .integer)
                t.column("output_head", .text)
                t.column("state", .text).notNull().defaults(to: RunHistoryState.known.rawValue)
                t.column("ran_at", .integer).notNull()
            }
            try db.create(index: "idx_run_history_host", on: "run_history", columns: ["host_uuid", "ran_at"])

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
