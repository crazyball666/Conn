import ConnKit
import ConnSSH
import Foundation
import Observation

enum SnippetListFilter: Hashable {
    case favorites
    case all
    case group(String)
}

/// 片段库 ViewModel（Phase 9）。
@Observable
@MainActor
final class SnippetsViewModel {
    private(set) var snippets: [Snippet] = []
    private(set) var groups: [String] = []
    var searchText = ""
    var errorMessage: String?

    private let store: any SnippetRepository

    init(store: any SnippetRepository) {
        self.store = store
    }

    func load() {
        do {
            snippets = try store.allSnippets()
            groups = try store.allFolders()
            errorMessage = nil
        } catch {
            errorMessage = String(format: L("读取片段失败：%@"), error.friendlyDiagnosis)
            snippets = []
            groups = []
        }
    }

    private var searchResults: [Snippet] {
        guard !searchText.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.command.localizedCaseInsensitiveContains(searchText)
        }
    }

    func snippets(for filter: SnippetListFilter) -> [Snippet] {
        switch filter {
        case .favorites:
            searchResults.filter(\.pinned)
        case .all:
            searchResults
        case let .group(name):
            searchResults.filter { $0.folders.contains(name) }
        }
    }

    func commandCount(in group: String) -> Int {
        snippets.count { $0.folders.contains(group) }
    }

    var filteredGroups: [String] {
        guard !searchText.isEmpty else { return groups }
        return groups.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    func save(_ snippet: Snippet) {
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
        try? store.delete(id: snippet.id)
        load()
    }

    func addGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.saveFolder(trimmed)
            groups = try store.allFolders()
            errorMessage = nil
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func deleteGroup(_ name: String) {
        do {
            try store.deleteFolder(name)
            load()
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }
}
