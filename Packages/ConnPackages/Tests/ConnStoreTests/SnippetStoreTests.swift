import ConnKit
import Foundation
import Testing
@testable import ConnStore

@Suite("SnippetStore 读写")
struct SnippetStoreTests {
    private func makeStore() throws -> SnippetStore {
        try SnippetStore(database: AppDatabase.inMemory())
    }

    @Test("save 后 allSnippets 读回，置顶优先")
    func savesAndOrders() throws {
        let store = try makeStore()
        try store.save(Snippet(title: "普通", command: "ls", sortOrder: 1))
        try store.save(Snippet(title: "置顶", command: "df", pinned: true, sortOrder: 2))
        let snippets = try store.allSnippets()
        #expect(snippets.map(\.title) == ["置顶", "普通"])
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
    func softDeletes() throws {
        let store = try makeStore()
        let snippet = Snippet(title: "临时", command: "echo hi")
        try store.save(snippet)
        try store.softDelete(id: snippet.id)
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
}
