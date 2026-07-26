import ConnKit
import Testing
@testable import ConnRunner

private final class StubBuiltinSnippetRepository: SnippetRepository, @unchecked Sendable {
    var snippets: [Snippet] = []
    var folders: [String] = []
    private var tombstoneCount = 0

    func allSnippets() throws -> [Snippet] { snippets }
    func snippet(id: String) throws -> Snippet? { snippets.first { $0.id == id } }
    func save(_ snippet: Snippet) throws {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
    }
    func softDelete(id: String) throws {
        if snippets.contains(where: { $0.id == id }) {
            tombstoneCount += 1
            snippets.removeAll { $0.id == id }
        }
    }
    func count() throws -> Int { snippets.count }
    func totalCount() throws -> Int { snippets.count + tombstoneCount }
    func allFolders() throws -> [String] { folders }
    func saveFolder(_ name: String) throws {
        if !folders.contains(name) { folders.append(name) }
    }
    func deleteFolder(_ name: String) throws { folders.removeAll { $0 == name } }
}

struct BuiltinSnippetsTests {
    @Test("内置库加载 ≥20 条")
    func loadsLibrary() {
        let snippets = BuiltinSnippets.load()
        #expect(snippets.count >= 20)
    }

    @Test("内置 JSON 同时声明有序分组")
    func loadsOrderedFolders() {
        #expect(BuiltinSnippets.loadFolders() == ["系统", "磁盘", "网络", "日志", "Docker", "服务"])
    }

    @Test("默认数据只导入一次，用户删光后也不会补回")
    func importsOnlyOnce() throws {
        let store = StubBuiltinSnippetRepository()

        #expect(try BuiltinSnippets.importIfNeeded(into: store))
        for snippet in store.snippets {
            try store.softDelete(id: snippet.id)
        }
        #expect(try !BuiltinSnippets.importIfNeeded(into: store))
        #expect(store.snippets.isEmpty)
    }

    @Test("每条都有标题与命令，排序权重递增")
    func wellFormed() {
        let snippets = BuiltinSnippets.load()
        #expect(snippets.allSatisfy { !$0.title.isEmpty && !$0.command.isEmpty })
        #expect(snippets.map(\.sortOrder) == Array(0 ..< snippets.count))
    }

    @Test("含危险片段标记（清理类）")
    func hasDangerFlagged() {
        let snippets = BuiltinSnippets.load()
        #expect(snippets.contains { $0.danger })
    }

    @Test("含置顶片段")
    func hasPinned() {
        #expect(BuiltinSnippets.load().contains { $0.pinned })
    }

    @Test("变量片段可被 ConnKit 解析")
    func variablesParse() {
        let snippets = BuiltinSnippets.load()
        let portSnippet = snippets.first { $0.command.contains("{{port") }
        #expect(portSnippet != nil)
        #expect(portSnippet?.variables.contains { $0.name == "port" } == true)
    }

    @Test("Docker 片段不把 Go 模板误判为变量")
    func dockerTemplatesNotVariables() {
        // 内置 docker 片段用 `docker ps -a`（无 {{json .}}），确保无误判变量
        let snippets = BuiltinSnippets.load()
        for snippet in snippets where snippet.command.hasPrefix("docker") {
            #expect(snippet.variables.allSatisfy { !$0.name.contains(".") })
        }
    }
}
