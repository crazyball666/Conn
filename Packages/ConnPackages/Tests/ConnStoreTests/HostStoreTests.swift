import ConnKit
import Foundation
import GRDB
import Testing
@testable import ConnStore

private typealias DomainHost = ConnKit.Host

@Suite("HostStore 读写")
struct HostStoreTests {
    private func makeStore() throws -> (HostStore, AppDatabase) {
        let database = try AppDatabase.inMemory()
        return (HostStore(database: database), database)
    }

    @Test("save 后可由 allHosts 读回")
    func savesAndLists() throws {
        let (store, _) = try makeStore()
        try store.save(DomainHost(name: "web-01", address: "10.0.0.1", username: "root"))
        try store.save(DomainHost(name: "db-01", address: "10.0.0.2", username: "root"))

        let hosts = try store.allHosts()
        #expect(hosts.count == 2)
        // 同 sortOrder 时按名称升序 → db-01 在前
        #expect(hosts.map(\.name) == ["db-01", "web-01"])
    }

    @Test("save 会置 syncDirty 并刷新 updatedAt")
    func savingMarksDirty() throws {
        let (store, _) = try makeStore()
        let host = DomainHost(name: "a", address: "1", username: "r", createdAt: 1000, updatedAt: 1000)
        try store.save(host)

        let loaded = try #require(try store.host(id: host.id))
        #expect(loaded.syncDirty)
        #expect(loaded.updatedAt > 1000)
        #expect(loaded.createdAt == 1000)
    }

    @Test("sortOrder 优先于名称排序")
    func respectsSortOrder() throws {
        let (store, _) = try makeStore()
        try store.save(DomainHost(name: "aaa", address: "1", username: "r", sortOrder: 5))
        try store.save(DomainHost(name: "zzz", address: "2", username: "r", sortOrder: 1))

        #expect(try store.allHosts().map(\.name) == ["zzz", "aaa"])
    }

    @Test("softDelete 后不再出现在列表与单查中")
    func softDeleteHidesHost() throws {
        let (store, _) = try makeStore()
        let host = DomainHost(name: "web-01", address: "10.0.0.1", username: "root")
        try store.save(host)
        try store.softDelete(id: host.id)

        #expect(try store.allHosts().isEmpty)
        #expect(try store.host(id: host.id) == nil)
    }

    @Test("softDelete 保留行与墓碑时间戳，不做物理删除")
    func softDeleteKeepsTombstone() throws {
        let (store, database) = try makeStore()
        let host = DomainHost(name: "web-01", address: "10.0.0.1", username: "root")
        try store.save(host)
        try store.softDelete(id: host.id)

        let row = try database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT deleted_at, sync_dirty FROM host WHERE uuid = ?", arguments: [host.id])
        }
        let deletedAt: Int64? = row?["deleted_at"]
        #expect(deletedAt != nil)
        #expect(row?["sync_dirty"] == 1)
    }

    @Test("save 同一 id 为覆盖而非新增")
    func saveIsUpsert() throws {
        let (store, _) = try makeStore()
        var host = DomainHost(name: "old", address: "1", username: "r")
        try store.save(host)
        host.name = "new"
        try store.save(host)

        let hosts = try store.allHosts()
        #expect(hosts.count == 1)
        #expect(hosts.first?.name == "new")
    }
}
