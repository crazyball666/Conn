import ConnKit
import ConnSSH
import Foundation
import Observation

enum SnippetListFilter: Hashable {
    case favorites
    case all
    /// 载荷是 `SnippetGroup.id`——按 id 而非名称关联，重命名分组不影响筛选。
    case group(String)
}

/// 片段库 ViewModel（Phase 9）。
@Observable
@MainActor
final class SnippetsViewModel {
    private(set) var snippets: [Snippet] = []
    private(set) var groups: [SnippetGroup] = []
    var searchText = ""
    private(set) var errorMessage: String?

    private let store: any SnippetRepository
    private let groupStore: any SnippetGroupRepository

    init(store: any SnippetRepository, groupStore: any SnippetGroupRepository) {
        self.store = store
        self.groupStore = groupStore
    }

    func load() {
        errorMessage = nil
        do {
            snippets = try store.allSnippets()
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch {
            errorMessage = L("读取片段失败，请重试")
            snippets = []
            groups = []
        }
    }

    private var searchResults: [Snippet] {
        guard !searchText.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.script.localizedCaseInsensitiveContains(searchText)
        }
    }

    func snippets(for filter: SnippetListFilter) -> [Snippet] {
        switch filter {
        case .favorites:
            searchResults.filter(\.pinned)
        case .all:
            searchResults
        case let .group(id):
            searchResults.filter { $0.groupIDs.contains(id) }
        }
    }

    func scriptCount(in groupID: String) -> Int {
        snippets.count { $0.groupIDs.contains(groupID) }
    }

    var filteredGroups: [SnippetGroup] {
        guard !searchText.isEmpty else { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func save(_ snippet: Snippet) {
        errorMessage = nil
        do {
            var value = snippet
            if !snippets.contains(where: { $0.id == value.id }) {
                value.sortOrder = (snippets.map(\.sortOrder).max() ?? -1) + 1
            }
            try store.save(value)
            load()
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func delete(_ snippet: Snippet) {
        errorMessage = nil
        do {
            try store.delete(id: snippet.id)
            load()
        } catch {
            errorMessage = String(format: L("删除失败：%@"), error.friendlyDiagnosis)
        }
    }

    // MARK: - 分组

    func addGroup(_ name: String) {
        errorMessage = nil
        do {
            let trimmed = try GroupListEditor.validate(name: name, against: groups.map(\.name))
            try groupStore.save(SnippetGroup(
                name: trimmed,
                sortOrder: GroupListEditor.nextSortOrder(after: groups.map(\.sortOrder))
            ))
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch let failure as GroupListEditor.Failure {
            errorMessage = failure.message
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func renameGroup(id: String, to name: String) {
        guard var group = groups.first(where: { $0.id == id }) else { return }
        errorMessage = nil
        do {
            let others = groups.filter { $0.id != id }.map(\.name)
            group.name = try GroupListEditor.validate(name: name, against: others)
            try groupStore.save(group)
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch let failure as GroupListEditor.Failure {
            errorMessage = failure.message
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    /// 删除分组只解除归属，脚本本身不受影响（成员行由外键级联清理）。
    func deleteGroup(id: String) {
        errorMessage = nil
        do {
            try groupStore.delete(id: id)
            load()
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
