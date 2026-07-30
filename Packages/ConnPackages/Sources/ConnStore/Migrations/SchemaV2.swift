import ConnKit
import Foundation
import GRDB

/// v2 只追加运行审计结果状态；已发布的 v1 迁移必须保持字节级语义不变。
enum SchemaV2 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_run_history_state") { db in
            try db.alter(table: "run_history") { table in
                table.add(column: "state", .text).notNull().defaults(to: RunHistoryState.known.rawValue)
            }
            // v1 的 nil 退出码代表当时没有拿到终态；默认值只服务于原本有退出码的行。
            try db.execute(
                sql: "UPDATE run_history SET state = ? WHERE exit_code IS NULL",
                arguments: [RunHistoryState.unknown.rawValue]
            )
        }
    }
}
