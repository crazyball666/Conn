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

    @Test("落盘 DatabasePool 可连续新增主机且不依赖终端配置表")
    func onDiskPoolSavesHostsWithoutTerminalConfigurationPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ConnHostStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let database = try AppDatabase.onDisk(at: directory.appending(path: "conn.sqlite"))
        defer {
            try? database.writer.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let store = HostStore(database: database)

        for index in 0 ..< 50 {
            try store.save(DomainHost(
                id: "host-\(index)",
                name: "host-\(index)",
                address: "10.0.0.\(index + 1)",
                username: "root"
            ))
        }

        let result = try database.writer.read { db in
            let hostCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host") ?? -1
            let obsoleteTableExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
                arguments: ["terminal_backend_profile"]
            ) ?? true
            return (hostCount, obsoleteTableExists)
        }
        #expect(result.0 == 50)
        #expect(result.1 == false)
    }

    @Test("删除被主机引用的 SSH 密钥会原子解除主机引用")
    func deletingReferencedKeyDetachesHosts() throws {
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

        #expect(try keys.key(id: key.id) == nil)
        let detachedHost = try #require(try hosts.host(id: host.id))
        #expect(detachedHost.authKind == .key)
        #expect(detachedHost.keyUUID == nil)
        #expect(detachedHost.syncDirty)
    }

    @Test("未知认证方式返回可处理错误，不应直接崩溃")
    func unknownAuthKindIsReported() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO host (
                    uuid, name, address, port, username, auth_kind, credential_ref,
                    key_uuid, jump_chain, tags, icon, color, note, expire_at,
                    sort_order, status, created_at, updated_at, sync_dirty
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, '[]', '[]', NULL, NULL, NULL, NULL, 0, ?, 1, 1, 0)
                """, arguments: ["bad-host", "Bad", "10.0.0.1", 22, "root", "future-auth", "unknown"])
        }

        #expect(throws: HostStoreError.unknownAuthKind(rawValue: "future-auth")) {
            try HostStore(database: database).allHosts()
        }
    }

    @Test("未知密钥算法返回可处理错误，不应直接崩溃")
    func unknownKeyKindIsReported() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO ssh_key (
                    uuid, name, kind, public_key, private_ref, created_at, updated_at, sync_dirty
                ) VALUES (?, ?, ?, ?, NULL, 1, 1, 0)
                """, arguments: ["bad-key", "Bad", "future-algorithm", "ssh-ed25519 AAAA"])
        }

        #expect(throws: SSHKeyStoreError.unknownKind(rawValue: "future-algorithm")) {
            try SSHKeyStore(database: database).allKeys()
        }
    }
}
