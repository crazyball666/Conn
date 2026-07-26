import ConnKit
import Foundation
import Testing
@testable import Conn

private final class StubSnippetRepository: SnippetRepository, @unchecked Sendable {
    var snippets: [Snippet]
    var folders: [String]

    init(snippets: [Snippet] = [], folders: [String] = []) {
        self.snippets = snippets
        self.folders = folders
    }

    func allSnippets() throws -> [Snippet] { snippets }
    func snippet(id: String) throws -> Snippet? { snippets.first { $0.id == id } }
    func save(_ snippet: Snippet) throws { snippets.append(snippet) }
    func softDelete(id: String) throws { snippets.removeAll { $0.id == id } }
    func count() throws -> Int { snippets.count }
    func totalCount() throws -> Int { snippets.count }
    func allFolders() throws -> [String] { folders }
    func saveFolder(_ name: String) throws {
        folders.append(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func deleteFolder(_ name: String) throws {
        folders.removeAll { $0 == name }
        for index in snippets.indices {
            snippets[index].folders.removeAll { $0 == name }
        }
    }
}

@MainActor
struct SnippetsViewModelTests {
    @Test("加载命令时同步加载可选分组")
    func loadIncludesGroups() {
        let store = StubSnippetRepository(folders: ["Docker", "日志"])
        let viewModel = SnippetsViewModel(store: store)

        viewModel.load()

        #expect(viewModel.groups == ["Docker", "日志"])
    }

    @Test("新增分组后刷新选择列表")
    func addGroupRefreshesGroups() {
        let store = StubSnippetRepository()
        let viewModel = SnippetsViewModel(store: store)

        viewModel.addGroup("网络")

        #expect(viewModel.groups == ["网络"])
    }

    @Test("常用、全部和多分组筛选结果正确")
    func filtersCommands() {
        let favorite = Snippet(id: "favorite", title: "常用", command: "a", folders: ["系统"], pinned: true)
        let shared = Snippet(id: "shared", title: "共享", command: "b", folders: ["系统", "日志"])
        let ungrouped = Snippet(id: "ungrouped", title: "未分组", command: "c")
        let viewModel = SnippetsViewModel(
            store: StubSnippetRepository(snippets: [favorite, shared, ungrouped], folders: ["系统", "日志"])
        )
        viewModel.load()

        #expect(viewModel.snippets(for: .favorites).map(\.id) == ["favorite"])
        #expect(viewModel.snippets(for: .all).map(\.id) == ["favorite", "shared", "ungrouped"])
        #expect(viewModel.snippets(for: .group("系统")).map(\.id) == ["favorite", "shared"])
        #expect(viewModel.snippets(for: .group("日志")).map(\.id) == ["shared"])
    }

    @Test("删除分组后命令保留")
    func deletesFolderWithoutDeletingCommands() {
        let snippet = Snippet(id: "a", title: "A", command: "a", folders: ["系统", "日志"])
        let store = StubSnippetRepository(snippets: [snippet], folders: ["系统", "日志"])
        let viewModel = SnippetsViewModel(store: store)
        viewModel.load()

        viewModel.deleteGroup("系统")

        #expect(viewModel.groups == ["日志"])
        #expect(viewModel.snippets.map(\.folders) == [["日志"]])
    }

    @Test("切换到分组页后搜索词可筛选分组")
    func searchFiltersGroups() {
        let viewModel = SnippetsViewModel(
            store: StubSnippetRepository(folders: ["系统", "Docker", "日志"])
        )
        viewModel.load()
        viewModel.searchText = "日"

        #expect(viewModel.filteredGroups == ["日志"])
    }
}
