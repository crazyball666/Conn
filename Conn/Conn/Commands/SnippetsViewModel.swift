import ConnKit
import Foundation
import Observation

/// 片段库 ViewModel（Phase 9）。
@Observable
@MainActor
final class SnippetsViewModel {
    private(set) var snippets: [Snippet] = []
    var searchText = ""
    var errorMessage: String?

    private let store: any SnippetRepository

    init(store: any SnippetRepository) {
        self.store = store
    }

    func load() {
        do {
            snippets = try store.allSnippets()
            errorMessage = nil
        } catch {
            errorMessage = "读取片段失败：\(error.localizedDescription)"
            snippets = []
        }
    }

    private var filtered: [Snippet] {
        guard !searchText.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.command.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// 分区：置顶片段单列「常用」，其余按文件夹分组。
    var sections: [(title: String, items: [Snippet])] {
        let items = filtered
        var result: [(String, [Snippet])] = []
        let pinned = items.filter(\.pinned)
        if !pinned.isEmpty {
            result.append((L("常用"), pinned))
        }
        let rest = items.filter { !$0.pinned }
        let grouped = Dictionary(grouping: rest) { $0.folder ?? L("未分组") }
        for key in grouped.keys.sorted() {
            result.append((key, (grouped[key] ?? []).sorted { $0.sortOrder < $1.sortOrder }))
        }
        return result
    }

    func save(_ snippet: Snippet) {
        do {
            try store.save(snippet)
            load()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func delete(_ snippet: Snippet) {
        try? store.softDelete(id: snippet.id)
        load()
    }
}
