import ConnKit
import Foundation
import Testing
@testable import Conn

private final class StubSnippetRepository: SnippetRepository, @unchecked Sendable {
    var snippets: [Snippet]
    var loadError: Error?

    init(snippets: [Snippet] = []) {
        self.snippets = snippets
    }

    func allSnippets() throws -> [Snippet] {
        if let loadError { throw loadError }
        return snippets
    }
    func snippet(id: String) throws -> Snippet? { snippets.first { $0.id == id } }
    func save(_ snippet: Snippet) throws {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
    }
    func delete(id: String) throws { snippets.removeAll { $0.id == id } }
    func count() throws -> Int { snippets.count }
}

private struct DetailedStoreError: Error, CustomStringConvertible {
    var description: String {
        "column 'interpreter' does not exist while decoding SnippetRecord"
    }
}

/// 模拟 `snippet_group_membership` 的 `ON DELETE CASCADE`：删组时把成员 id 摘掉。
private final class StubSnippetGroupRepository: SnippetGroupRepository, @unchecked Sendable {
    var groups: [SnippetGroup]
    /// 级联需要改到命令上，因此持有片段仓库的引用。
    weak var snippetStore: StubSnippetRepository?

    init(groups: [SnippetGroup] = []) { self.groups = groups }

    func allGroups() throws -> [SnippetGroup] { groups.sorted { $0.sortOrder < $1.sortOrder } }

    func save(_ group: SnippetGroup) throws {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }

    func delete(id: String) throws {
        groups.removeAll { $0.id == id }
        guard let snippetStore else { return }
        for index in snippetStore.snippets.indices {
            snippetStore.snippets[index].groupIDs.removeAll { $0 == id }
        }
    }
}

@MainActor
struct SnippetsViewModelTests {
    private func makeViewModel(
        snippets: [Snippet] = [],
        groups: [SnippetGroup] = []
    ) -> (SnippetsViewModel, StubSnippetRepository, StubSnippetGroupRepository) {
        let store = StubSnippetRepository(snippets: snippets)
        let groupStore = StubSnippetGroupRepository(groups: groups)
        groupStore.snippetStore = store
        return (SnippetsViewModel(store: store, groupStore: groupStore), store, groupStore)
    }

    @Test("加载命令时同步加载可选分组")
    func loadIncludesGroups() {
        let docker = SnippetGroup(name: "Docker", sortOrder: 0)
        let logs = SnippetGroup(name: "日志", sortOrder: 1)
        let (viewModel, _, _) = makeViewModel(groups: [docker, logs])

        viewModel.load()

        #expect(viewModel.groups.map(\.name) == ["Docker", "日志"])
    }

    @Test("脚本读取失败时使用通用可操作文案")
    func loadFailureUsesGenericMessage() {
        let (viewModel, store, _) = makeViewModel()
        store.loadError = DetailedStoreError()

        viewModel.load()

        #expect(viewModel.errorMessage == L("读取片段失败，请重试"))
    }

    @Test("新增分组后刷新选择列表")
    func addGroupRefreshesGroups() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.addGroup("网络")

        #expect(viewModel.groups.map(\.name) == ["网络"])
    }

    @Test("常用、全部和多分组筛选结果正确")
    func filtersCommands() {
        let system = SnippetGroup(name: "系统", sortOrder: 0)
        let logs = SnippetGroup(name: "日志", sortOrder: 1)
        let favorite = Snippet(id: "favorite", title: "常用", script: "a", groupIDs: [system.id], pinned: true)
        let shared = Snippet(id: "shared", title: "共享", script: "b", groupIDs: [system.id, logs.id])
        let ungrouped = Snippet(id: "ungrouped", title: "未分组", script: "c")
        let (viewModel, _, _) = makeViewModel(
            snippets: [favorite, shared, ungrouped],
            groups: [system, logs]
        )
        viewModel.load()

        #expect(viewModel.snippets(for: .favorites).map(\.id) == ["favorite"])
        #expect(viewModel.snippets(for: .all).map(\.id) == ["favorite", "shared", "ungrouped"])
        #expect(viewModel.snippets(for: .group(system.id)).map(\.id) == ["favorite", "shared"])
        #expect(viewModel.snippets(for: .group(logs.id)).map(\.id) == ["shared"])
    }

    @Test("删除分组后命令保留")
    func deletesGroupWithoutDeletingCommands() {
        let system = SnippetGroup(name: "系统", sortOrder: 0)
        let logs = SnippetGroup(name: "日志", sortOrder: 1)
        let snippet = Snippet(id: "a", title: "A", script: "a", groupIDs: [system.id, logs.id])
        let (viewModel, _, _) = makeViewModel(snippets: [snippet], groups: [system, logs])
        viewModel.load()

        viewModel.deleteGroup(id: system.id)

        #expect(viewModel.groups.map(\.name) == ["日志"])
        #expect(viewModel.snippets.map(\.groupIDs) == [[logs.id]])
    }

    @Test("切换到分组页后搜索词可筛选分组")
    func searchFiltersGroups() {
        let (viewModel, _, _) = makeViewModel(groups: [
            SnippetGroup(name: "系统", sortOrder: 0),
            SnippetGroup(name: "Docker", sortOrder: 1),
            SnippetGroup(name: "日志", sortOrder: 2)
        ])
        viewModel.load()
        viewModel.searchText = "日"

        #expect(viewModel.filteredGroups.map(\.name) == ["日志"])
    }

    @Test("重名分组被拒并写入错误消息")
    func rejectsDuplicateGroupName() {
        let (viewModel, _, groupStore) = makeViewModel(groups: [SnippetGroup(name: "Docker")])
        viewModel.load()

        viewModel.addGroup(" docker ")

        #expect(groupStore.groups.count == 1)
        #expect(viewModel.errorMessage == L("已存在同名分组"))
    }

    @Test("重命名分组不影响成员关系")
    func renameGroupKeepsMembership() {
        let group = SnippetGroup(name: "旧名")
        let snippet = Snippet(title: "ls", script: "ls", groupIDs: [group.id])
        let (viewModel, _, groupStore) = makeViewModel(snippets: [snippet], groups: [group])
        viewModel.load()

        viewModel.renameGroup(id: group.id, to: "新名")

        #expect(groupStore.groups.map(\.name) == ["新名"])
        #expect(viewModel.snippets(for: .group(group.id)).map(\.title) == ["ls"])
    }

    @Test("按 id 统计组内命令数")
    func countsCommandsByGroupID() {
        let group = SnippetGroup(name: "系统")
        let (viewModel, _, _) = makeViewModel(
            snippets: [
                Snippet(title: "a", script: "a", groupIDs: [group.id]),
                Snippet(title: "b", script: "b")
            ],
            groups: [group]
        )
        viewModel.load()

        #expect(viewModel.scriptCount(in: group.id) == 1)
    }
}
