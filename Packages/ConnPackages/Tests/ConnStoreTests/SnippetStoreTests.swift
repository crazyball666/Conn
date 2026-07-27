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
        try store.save(Snippet(title: "普通", command: "ls", sortOrder: 1))
        try store.save(Snippet(title: "置顶", command: "df", pinned: true, sortOrder: 2))
        let snippets = try store.allSnippets()
        #expect(snippets.map(\.title) == ["普通", "置顶"])
    }

    @Test("count 统计未删除数量")
    func counts() throws {
        let store = try makeStore()
        #expect(try store.count() == 0)
        try store.save(Snippet(title: "a", command: "a"))
        try store.save(Snippet(title: "b", command: "b"))
        #expect(try store.count() == 2)
    }

    @Test("软删除后不再出现")
    func deletes() throws {
        let store = try makeStore()
        let snippet = Snippet(title: "临时", command: "echo hi")
        try store.save(snippet)
        try store.delete(id: snippet.id)
        #expect(try store.allSnippets().isEmpty)
        #expect(try store.snippet(id: snippet.id) == nil)
        #expect(try store.count() == 0)
    }

    @Test("同 id 保存为覆盖")
    func overwrites() throws {
        let store = try makeStore()
        let snippet = Snippet(title: "旧", command: "old")
        try store.save(snippet)
        var edited = snippet
        edited.title = "新"
        try store.save(edited)
        #expect(try store.allSnippets().count == 1)
        #expect(try store.snippet(id: snippet.id)?.title == "新")
    }

    @Test("新增分组持久化，并与已有命令分组合并去重")
    func foldersPersistAndIncludeExistingSnippetFolders() throws {
        let store = try makeStore()
        try store.saveFolder(" 网络 ")
        try store.saveFolder("网络")
        try store.save(Snippet(title: "容器", command: "docker ps", folder: "Docker"))

        #expect(try store.allFolders() == ["网络", "Docker"])
    }

    @Test("空白分组不会保存")
    func blankFolderIsIgnored() throws {
        let store = try makeStore()
        try store.saveFolder("   ")

        #expect(try store.allFolders().isEmpty)
    }

    @Test("命令支持多个分组，编辑后可移除全部分组")
    func multipleFoldersRoundTripAndCanBeCleared() throws {
        let store = try makeStore()
        var snippet = Snippet(
            title: "容器日志",
            command: "docker logs",
            folders: ["Docker", "日志"]
        )
        try store.save(snippet)

        #expect(Set(try #require(store.snippet(id: snippet.id)).folders) == ["Docker", "日志"])

        snippet.folders = []
        try store.save(snippet)

        #expect(try #require(store.snippet(id: snippet.id)).folders.isEmpty)
    }

    @Test("删除分组只解除归属，不删除组内命令")
    func deletingFolderKeepsCommands() throws {
        let store = try makeStore()
        let snippet = Snippet(
            title: "容器日志",
            command: "docker logs",
            folders: ["Docker", "日志"]
        )
        try store.save(snippet)

        try store.deleteFolder("Docker")

        #expect(try store.allFolders() == ["日志"])
        #expect(try store.snippet(id: snippet.id)?.folders == ["日志"])
    }
}
