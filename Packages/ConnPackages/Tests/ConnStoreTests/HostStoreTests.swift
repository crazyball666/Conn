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

    @Test("delete 后不再出现在列表与单查中")
    func deleteHidesHost() throws {
        let (store, _) = try makeStore()
        let host = DomainHost(name: "web-01", address: "10.0.0.1", username: "root")
        try store.save(host)
        try store.delete(id: host.id)

        #expect(try store.allHosts().isEmpty)
        #expect(try store.host(id: host.id) == nil)
    }

    @Test("delete 是真 DELETE，表中不留残行")
    func deleteRemovesRow() throws {
        let (store, database) = try makeStore()
        let host = DomainHost(name: "web-01", address: "10.0.0.1", username: "root")
        try store.save(host)
        try store.delete(id: host.id)

        let remaining = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host") ?? -1
        }
        #expect(remaining == 0)
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

    /// 锁住外键行为：`host.key_uuid` 的 SET NULL 级联在软删除时代从不触发，
    /// 改真删除后首次生效。KeyManagerView 的删除确认依赖这条行为提示用户。
    @Test("删除 SSH 密钥后，引用它的主机 key_uuid 被置空")
    func deletingKeyNullsHostReference() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let keys = SSHKeyStore(database: database)
        let key = SSHKey(name: "ed25519", kind: .ed25519, publicKey: "ssh-ed25519 AAAA")
        try keys.save(key)
        let host = DomainHost(
            name: "web", address: "1", username: "root",
            authKind: .key, keyUUID: key.id
        )
        try hosts.save(host)

        try keys.delete(id: key.id)

        #expect(try hosts.host(id: host.id)?.keyUUID == nil)
    }
}
