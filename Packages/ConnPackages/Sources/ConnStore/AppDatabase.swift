import Foundation
import GRDB

/// GRDB 数据库门面。构造即完成迁移。
///
/// 数据全部只存本机（红线：无服务端、零上传）。凭据不在此库中——
/// 密码与私钥存 Keychain / Secure Enclave，本库只存引用键。
public struct AppDatabase {
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

    /// 迁移器。新增 schema 版本时在此追加，**已发布的迁移不得修改**。
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // 开发期 schema 变更后自动重建，避免手动删 App
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        SchemaV1.register(in: &migrator)
        return migrator
    }

    private static var baseConfiguration: Configuration {
        var config = Configuration()
        // 外键约束必须开启：host.group_uuid / host.key_uuid 依赖它保证引用完整性
        config.foreignKeysEnabled = true
        return config
    }
}
