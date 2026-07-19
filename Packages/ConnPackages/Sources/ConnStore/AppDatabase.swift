import Foundation
import GRDB

/// GRDB 数据库门面。Task 4 补齐迁移与 DAO。
public struct AppDatabase {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }
}
