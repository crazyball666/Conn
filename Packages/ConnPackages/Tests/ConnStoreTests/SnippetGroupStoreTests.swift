import ConnKit
import Foundation
import Testing
@testable import ConnStore

@Suite("SnippetGroupStore — 命令分组")
struct SnippetGroupStoreTests {
    private func makeStores() throws -> (SnippetStore, SnippetGroupStore) {
        let database = try AppDatabase.inMemory()
        return (SnippetStore(database: database), SnippetGroupStore(database: database))
    }

    @Test("重命名分组不影响成员关系")
    func renameKeepsMembership() throws {
        let (snippets, groups) = try makeStores()
        var group = SnippetGroup(name: "旧名")
        try groups.save(group)
        let snippet = Snippet(title: "ls", script: "ls", groupIDs: [group.id])
        try snippets.save(snippet)

        group.name = "新名"
        try groups.save(group)

        #expect(try groups.allGroups().map(\.name) == ["新名"])
        #expect(try snippets.snippet(id: snippet.id)?.groupIDs == [group.id])
    }

    @Test("删除分组级联清掉成员行，命令本身仍在")
    func deleteCascadesMembership() throws {
        let (snippets, groups) = try makeStores()
        let group = SnippetGroup(name: "Docker")
        try groups.save(group)
        let snippet = Snippet(title: "ps", script: "docker ps", groupIDs: [group.id])
        try snippets.save(snippet)

        try groups.delete(id: group.id)

        #expect(try snippets.snippet(id: snippet.id)?.groupIDs == [])
        #expect(try snippets.count() == 1)
    }

    @Test("删除命令级联清掉成员行")
    func deletingSnippetCascadesMembership() throws {
        let (snippets, groups) = try makeStores()
        let group = SnippetGroup(name: "系统")
        try groups.save(group)
        let snippet = Snippet(title: "df", script: "df -h", groupIDs: [group.id])
        try snippets.save(snippet)

        try snippets.delete(id: snippet.id)

        #expect(try groups.allGroups().count == 1)
        #expect(try snippets.count() == 0)
    }

    @Test("保存时携带不存在的分组 id 会被静默丢弃")
    func unknownGroupIDIsDropped() throws {
        let (snippets, groups) = try makeStores()
        let group = SnippetGroup(name: "系统")
        try groups.save(group)
        let snippet = Snippet(title: "df", script: "df -h", groupIDs: [group.id, "does-not-exist"])

        try snippets.save(snippet)

        #expect(try snippets.snippet(id: snippet.id)?.groupIDs == [group.id])
    }

    @Test("成员按分组的排序权重返回")
    func membershipFollowsGroupOrder() throws {
        let (snippets, groups) = try makeStores()
        let later = SnippetGroup(name: "B", sortOrder: 5)
        let earlier = SnippetGroup(name: "A", sortOrder: 1)
        try groups.save(later)
        try groups.save(earlier)
        let snippet = Snippet(title: "ls", script: "ls", groupIDs: [later.id, earlier.id])

        try snippets.save(snippet)

        #expect(try snippets.snippet(id: snippet.id)?.groupIDs == [earlier.id, later.id])
    }
}
