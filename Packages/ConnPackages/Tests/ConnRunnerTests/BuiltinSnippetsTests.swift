import ConnKit
import Testing
@testable import ConnRunner

struct BuiltinSnippetsTests {
    @Test("内置库加载 ≥20 条")
    func loadsLibrary() {
        let snippets = BuiltinSnippets.load()
        #expect(snippets.count >= 20)
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
