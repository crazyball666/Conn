import ConnKit
import Foundation
import Testing
@testable import ConnStore

@Suite("HostGroupStore — 分组 CRUD")
struct HostGroupStoreTests {
    private func makeStore() throws -> HostGroupStore {
        try HostGroupStore(database: AppDatabase.inMemory())
    }

    @Test("保存后可读回，按排序权重排序")
    func savesAndOrders() throws {
        let store = try makeStore()
        try store.save(HostGroup(name: "生产", sortOrder: 1))
        try store.save(HostGroup(name: "测试", sortOrder: 0))
        #expect(try store.allGroups().map(\.name) == ["测试", "生产"])
    }

    @Test("删除后不再出现")
    func deleteRemovesGroup() throws {
        let store = try makeStore()
        let group = HostGroup(name: "临时")
        try store.save(group)
        try store.delete(id: group.id)
        #expect(try store.allGroups().isEmpty)
    }

    @Test("同 id 保存为覆盖")
    func saveIsUpsert() throws {
        let store = try makeStore()
        var group = HostGroup(name: "旧名")
        try store.save(group)
        group.name = "新名"
        try store.save(group)
        let groups = try store.allGroups()
        #expect(groups.count == 1)
        #expect(groups.first?.name == "新名")
    }

    @Test("主机可属于多个分组，重命名不影响成员关系")
    func multiGroupMembership() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let store = HostGroupStore(database: database)
        var prod = HostGroup(name: "生产", sortOrder: 0)
        let web = HostGroup(name: "Web", sortOrder: 1)
        try store.save(prod)
        try store.save(web)
        let host = ConnKit.Host(
            name: "web-01", address: "10.0.0.1", username: "root",
            groupIDs: [prod.id, web.id]
        )
        try hosts.save(host)

        prod.name = "PROD"
        try store.save(prod)

        #expect(try hosts.host(id: host.id)?.groupIDs == [prod.id, web.id])
    }

    @Test("删除分组级联清成员行，主机仍在")
    func deleteCascadesMembership() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let store = HostGroupStore(database: database)
        let group = HostGroup(name: "临时")
        try store.save(group)
        let host = ConnKit.Host(name: "a", address: "1", username: "r", groupIDs: [group.id])
        try hosts.save(host)

        try store.delete(id: group.id)

        #expect(try hosts.host(id: host.id)?.groupIDs == [])
        #expect(try hosts.allHosts().count == 1)
    }

    @Test("删除主机级联清成员行，分组仍在")
    func deletingHostCascadesMembership() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let store = HostGroupStore(database: database)
        let group = HostGroup(name: "生产")
        try store.save(group)
        let host = ConnKit.Host(name: "a", address: "1", username: "r", groupIDs: [group.id])
        try hosts.save(host)

        try hosts.delete(id: host.id)

        #expect(try store.allGroups().count == 1)
        #expect(try hosts.allHosts().isEmpty)
    }

    @Test("保存时携带不存在的分组 id 会被静默丢弃")
    func unknownGroupIDIsDropped() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let store = HostGroupStore(database: database)
        let group = HostGroup(name: "生产")
        try store.save(group)
        let host = ConnKit.Host(
            name: "a", address: "1", username: "r",
            groupIDs: [group.id, "does-not-exist"]
        )

        try hosts.save(host)

        #expect(try hosts.host(id: host.id)?.groupIDs == [group.id])
    }
}
