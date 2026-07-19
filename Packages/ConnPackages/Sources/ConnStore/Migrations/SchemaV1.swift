import Foundation
import GRDB

enum SchemaV1 {
    /// 注册 v1 建表迁移。
    ///
    /// 命名遵循技术实现方案 §3：蛇形字段名；所有实体表带 `uuid` 主键、
    /// `created_at`/`updated_at`（毫秒），并为 v1.1 同步预留 `sync_dirty`
    /// 与 `deleted_at` 墓碑字段。
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
                t.column("deleted_at", .integer)
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
                t.column("deleted_at", .integer)
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
                t.column("group_uuid", .text).references("host_group", column: "uuid", onDelete: .setNull)
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
                t.column("deleted_at", .integer)
            }
            try db.create(index: "idx_host_group", on: "host", columns: ["group_uuid"])
            try db.create(index: "idx_host_deleted", on: "host", columns: ["deleted_at"])

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
                t.column("folder", .text)
                t.column("pinned", .integer).notNull().defaults(to: 0)
                t.column("danger", .integer).notNull().defaults(to: 0)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
                t.column("deleted_at", .integer)
            }

            try db.create(table: "run_history") { t in
                t.primaryKey("uuid", .text)
                t.column("host_uuid", .text).notNull()
                t.column("command", .text).notNull()
                t.column("exit_code", .integer)
                t.column("output_head", .text)
                t.column("ran_at", .integer).notNull()
            }
            try db.create(index: "idx_run_history_host", on: "run_history", columns: ["host_uuid", "ran_at"])

            // 时序表：原始采样保留 48h，启动时清理
            try db.create(table: "metric_sample") { t in
                t.column("host_uuid", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("cpu", .double).notNull()
                t.column("mem", .double).notNull()
                t.column("load1", .double).notNull()
                t.column("disk_used", .double).notNull()
                t.column("disk_total", .double).notNull()
                t.column("net_rx", .integer).notNull()
                t.column("net_tx", .integer).notNull()
                t.primaryKey(["host_uuid", "ts"])
            }

            try db.create(table: "probe_target") { t in
                t.primaryKey("uuid", .text)
                t.column("kind", .text).notNull() // http | tcp | ping
                t.column("endpoint", .text).notNull()
                t.column("host_uuid", .text)
                t.column("last_status", .text)
                t.column("last_latency_ms", .integer)
                t.column("cert_expire_at", .integer)
            }

            try db.create(table: "app_setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
    }
}
