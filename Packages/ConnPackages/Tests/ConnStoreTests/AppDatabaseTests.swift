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
            try db.execute(sql: """
            INSERT INTO host_group (uuid, name, sort_order, created_at, updated_at)
            VALUES ('g1', '生产', 0, 1, 1)
            """)
        }

        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        // 重开同一文件，确认数据真的落盘且迁移幂等
        let reopened = try AppDatabase.onDisk(at: dbURL)
        let value = try reopened.writer.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM host_group WHERE uuid = 'g1'")
        }
        #expect(value == "生产")
    }

    @Test("外键约束在配置中已开启")
    func foreignKeysEnabled() throws {
        let database = try AppDatabase.inMemory()
        let enabled = try database.writer.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(enabled == 1)
    }

    @Test("本地数据库重置会删除主文件与事务旁路文件并允许重新建库")
    func removesOnDiskStoreAndAllowsRecreation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ConnResetTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("Conn/conn.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let database = try AppDatabase.onDisk(at: dbURL)
            try database.writer.write { db in
                try db.execute(sql: """
                INSERT INTO host_group (uuid, name, sort_order, created_at, updated_at)
                VALUES ('to-delete', '旧数据', 0, 1, 1)
                """)
            }
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data("sidecar".utf8).write(to: URL(fileURLWithPath: dbURL.path + suffix))
        }

        try AppDatabase.removeOnDiskStore(at: dbURL)

        #expect(!FileManager.default.fileExists(atPath: dbURL.path))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-shm"))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-journal"))
        let recreated = try AppDatabase.onDisk(at: dbURL)
        let count = try recreated.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host_group")
        }
        #expect(count == 0)
    }
}
