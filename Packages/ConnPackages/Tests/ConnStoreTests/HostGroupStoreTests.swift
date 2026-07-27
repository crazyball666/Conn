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
}
