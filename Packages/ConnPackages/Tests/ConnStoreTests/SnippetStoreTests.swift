import ConnKit
import Foundation
import Testing
@testable import ConnStore

@Suite("SnippetStore 读写")
struct SnippetStoreTests {
    private func makeStore() throws -> SnippetStore {
        try SnippetStore(database: AppDatabase.inMemory())
    }

    @Test("save 后 allSnippets 按排序权重读回")
    func savesAndOrders() throws {
        let store = try makeStore()
        try store.save(Snippet(title: "普通", script: "ls", sortOrder: 1))
        try store.save(Snippet(title: "置顶", script: "df", pinned: true, sortOrder: 2))
        let snippets = try store.allSnippets()
        #expect(snippets.map(\.title) == ["普通", "置顶"])
    }

    @Test("count 统计命令数量")
    func counts() throws {
        let store = try makeStore()
        #expect(try store.count() == 0)
        try store.save(Snippet(title: "a", script: "a"))
        try store.save(Snippet(title: "b", script: "b"))
        #expect(try store.count() == 2)
    }

    @Test("删除后不再出现")
    func deletes() throws {
        let store = try makeStore()
        let snippet = Snippet(title: "临时", script: "echo hi")
        try store.save(snippet)
        try store.delete(id: snippet.id)
        #expect(try store.allSnippets().isEmpty)
        #expect(try store.snippet(id: snippet.id) == nil)
        #expect(try store.count() == 0)
    }

    @Test("同 id 保存为覆盖")
    func overwrites() throws {
        let store = try makeStore()
        let snippet = Snippet(title: "旧", script: "old")
        try store.save(snippet)
        var edited = snippet
        edited.title = "新"
        try store.save(edited)
        #expect(try store.allSnippets().count == 1)
        #expect(try store.snippet(id: snippet.id)?.title == "新")
    }

    @Test("命令支持多个分组，编辑后可移除全部分组")
    func multipleGroupsRoundTripAndCanBeCleared() throws {
        let database = try AppDatabase.inMemory()
        let store = SnippetStore(database: database)
        let groups = SnippetGroupStore(database: database)
        let docker = SnippetGroup(name: "Docker", sortOrder: 0)
        let logs = SnippetGroup(name: "日志", sortOrder: 1)
        try groups.save(docker)
        try groups.save(logs)
        var snippet = Snippet(title: "容器日志", script: "docker logs", groupIDs: [docker.id, logs.id])
        try store.save(snippet)

        #expect(try #require(store.snippet(id: snippet.id)).groupIDs == [docker.id, logs.id])

        snippet.groupIDs = []
        try store.save(snippet)

        #expect(try #require(store.snippet(id: snippet.id)).groupIDs.isEmpty)
    }

    @Test("删除分组只解除归属，不删除组内命令")
    func deletingGroupKeepsCommands() throws {
        let database = try AppDatabase.inMemory()
        let store = SnippetStore(database: database)
        let groups = SnippetGroupStore(database: database)
        let docker = SnippetGroup(name: "Docker", sortOrder: 0)
        let logs = SnippetGroup(name: "日志", sortOrder: 1)
        try groups.save(docker)
        try groups.save(logs)
        let snippet = Snippet(title: "容器日志", script: "docker logs", groupIDs: [docker.id, logs.id])
        try store.save(snippet)

        try groups.delete(id: docker.id)

        #expect(try groups.allGroups().map(\.name) == ["日志"])
        #expect(try store.snippet(id: snippet.id)?.groupIDs == [logs.id])
    }
}
