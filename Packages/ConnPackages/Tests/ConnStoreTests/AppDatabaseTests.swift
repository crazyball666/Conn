import Foundation
import GRDB
import Testing
@testable import ConnStore

@Suite("AppDatabase 构造")
struct AppDatabaseTests {
    @Test("可用内存 DatabaseQueue 构造")
    func constructsWithInMemoryQueue() throws {
        let database = AppDatabase(try DatabaseQueue())
        let one = try database.writer.read { try Int.fetchOne($0, sql: "SELECT 1") }
        #expect(one == 1)
    }
}
