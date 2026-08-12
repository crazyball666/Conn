import Foundation
import GRDB

/// GRDB 数据库门面。构造即完成迁移。
///
/// 数据全部只存本机（红线：无服务端、零上传）。凭据不在此库中——
/// 密码与私钥存 Keychain，本库只存引用键。
/// GRDB 的 `DatabaseWriter`（`DatabaseQueue` / `DatabasePool`）本身提供线程安全的
/// writer API，但当前 GRDB 7 的协议没有声明 `Sendable`。数据库门面只转发这些
/// writer 操作，不把 `Database` 实例跨并发域保存，因此这里显式标注其并发边界。
public struct AppDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter

    /// 用给定 writer 构造并立即执行迁移。
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 内存库，供单元测试使用。
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: baseConfiguration))
    }

    /// 磁盘库，供 App 使用。
    ///
    /// - Parameter url: 数据库文件路径，通常为
    ///   `Application Support/Conn/conn.sqlite`。
    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(DatabasePool(path: url.path, configuration: baseConfiguration))
    }

    /// 迁移器。预发布阶段由初始 schema 创建空数据库。
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
            // 开发期 schema 变更后自动重建，避免手动删 App
            migrator.eraseDatabaseOnSchemaChange = true
        #endif
        SchemaV1.register(in: &migrator)
        SchemaV2.register(in: &migrator)
        SchemaV3.register(in: &migrator)
        SchemaV4.register(in: &migrator)
        return migrator
    }

    private static var baseConfiguration: Configuration {
        var config = Configuration()
        // 外键约束必须开启：host.key_uuid 与两张成员表的 ON DELETE CASCADE 依赖它。
        // 改真删除后这些级联才第一次真正触发（软删除时代从不触发）。
        config.foreignKeysEnabled = true
        return config
    }
}
