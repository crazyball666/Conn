import Foundation
import GRDB
import Testing
@testable import ConnStore

@Suite("AppDatabase 构造")
struct AppDatabaseTests {
    @Test("内存库构造后可执行查询")
    func constructsInMemory() throws {
        let database = try AppDatabase.inMemory()
        let one = try database.writer.read { try Int.fetchOne($0, sql: "SELECT 1") }
        #expect(one == 1)
    }

    @Test("磁盘库会自动创建父目录并落盘")
    func createsParentDirectoryOnDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ConnTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("Conn/conn.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try AppDatabase.onDisk(at: dbURL)
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO app_setting (key, value) VALUES ('theme', 'dark')")
        }

        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        // 重开同一文件，确认数据真的落盘且迁移幂等
        let reopened = try AppDatabase.onDisk(at: dbURL)
        let value = try reopened.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_setting WHERE key = 'theme'")
        }
        #expect(value == "dark")
    }

    @Test("外键约束在配置中已开启")
    func foreignKeysEnabled() throws {
        let database = try AppDatabase.inMemory()
        let enabled = try database.writer.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(enabled == 1)
    }
}
