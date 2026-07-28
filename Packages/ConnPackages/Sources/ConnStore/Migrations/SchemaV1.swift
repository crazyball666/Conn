import Foundation
import GRDB

enum SchemaV1 {
    /// 注册 v1 建表迁移。
    ///
    /// 命名遵循技术实现方案 §3：蛇形字段名；所有实体表带 `uuid` 主键、
    /// `created_at`/`updated_at`（毫秒）与 `sync_dirty`。
    ///
    /// **有意偏离 §3 的一点：不设 `deleted_at` 墓碑，删除一律真 DELETE。**
    /// 墓碑的唯一收益是让 v1.1 同步能传播删除，代价是每个查询都得记得写
    /// `WHERE deleted_at IS NULL`（漏一次即数据泄漏）。删除传播留待 v1.1
    /// 立项时重新决策，详见 docs/superpowers/specs/2026-07-27-server-groups-design.md。
    ///
    /// 长度由表数量决定而非逻辑复杂度；拆分会破坏「一次迁移 = 一个原子单元」
    /// 的语义，故豁免函数长度检查。
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
                // Keychain / Secure Enclave 引用键，非私钥本身
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
                t.column("key_uuid", .text).references("ssh_key", column: "uuid", onDelete: .setNull)
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
                t.column("command", .text).notNull()
                t.column("pinned", .integer).notNull().defaults(to: 0)
                t.column("danger", .integer).notNull().defaults(to: 0)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "snippet_group") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }

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
                t.column("command", .text).notNull()
                t.column("exit_code", .integer)
                t.column("output_head", .text)
                t.column("ran_at", .integer).notNull()
            }
            try db.create(index: "idx_run_history_host", on: "run_history", columns: ["host_uuid", "ran_at"])

        }
    }
}
