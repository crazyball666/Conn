import ConnKit
import Testing
@testable import ConnRunner

private final class StubBuiltinSnippetRepository: SnippetRepository, @unchecked Sendable {
    var snippets: [Snippet] = []
    var suppressedKeys: Set<String> = []
    var catalogVersion = 0

    func allSnippets() throws -> [Snippet] { snippets }
    func snippet(id: String) throws -> Snippet? { snippets.first { $0.id == id } }
    func save(_ snippet: Snippet) throws {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
    }
    func delete(id: String) throws {
        if let key = snippets.first(where: { $0.id == id })?.builtinKey {
            suppressedKeys.insert(key)
        }
        snippets.removeAll { $0.id == id }
    }
    func isBuiltinSuppressed(_ builtinKey: String) throws -> Bool {
        suppressedKeys.contains(builtinKey)
    }
    func suppressBuiltin(_ builtinKey: String) throws { suppressedKeys.insert(builtinKey) }
    func builtinCatalogVersion() throws -> Int { catalogVersion }
    func setBuiltinCatalogVersion(_ version: Int) throws { catalogVersion = version }
    func count() throws -> Int { snippets.count }
}

private final class StubBuiltinGroupRepository: SnippetGroupRepository, @unchecked Sendable {
    var groups: [SnippetGroup] = []

    func allGroups() throws -> [SnippetGroup] { groups.sorted { $0.sortOrder < $1.sortOrder } }
    func save(_ group: SnippetGroup) throws {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }
    func delete(id: String) throws { groups.removeAll { $0.id == id } }
}

struct BuiltinSnippetsTests {
    @Test("内置库同时提供 Linux 与 macOS 等价命令")
    func loadsLibrary() {
        let snippets = BuiltinSnippets.load()
        #expect(snippets.count > 10)
        #expect(snippets.contains { $0.platforms == [.linux] && $0.script.contains("systemctl") })
        #expect(snippets.contains { $0.platforms == [.macOS] && $0.script.contains("sysctl") })
        #expect(snippets.contains { $0.platforms == [.macOS] && $0.script.contains("log show") })
    }

    @Test("每条内置命令都有唯一稳定 key")
    func stableKeysAreUnique() throws {
        let snippets = BuiltinSnippets.load()
        let keys = try snippets.map { try #require($0.builtinKey) }

        #expect(Set(keys).count == snippets.count)
        #expect(BuiltinSnippets.catalogVersion > 0)
    }

    @Test("Docker 片段按能力而不是操作系统过滤")
    func dockerEntriesRequireCapability() {
        let docker = BuiltinSnippets.load().filter { $0.script.hasPrefix("docker ") }

        #expect(!docker.isEmpty)
        #expect(docker.allSatisfy { $0.platforms.isEmpty })
        #expect(docker.allSatisfy { $0.requiredCapabilities == [.docker] })
    }

    @Test("内置 JSON 同时声明有序分组")
    func loadsOrderedGroupNames() {
        #expect(BuiltinSnippets.loadGroupNames() == ["系统", "磁盘", "网络", "日志", "Docker"])
    }

    /// 「是否需要导入」的判定已上移到调用方（`SettingsStore.builtinSnippetsImported`）——
    /// 改真删除后墓碑不存在，仓库无法再区分「从未导入」与「用户删光了」。
    @Test("导入会写入全部内置分组与命令")
    func importsFullLibrary() throws {
        let store = StubBuiltinSnippetRepository()
        let groups = StubBuiltinGroupRepository()

        #expect(try BuiltinSnippets.importIfNeeded(into: store, groups: groups))

        #expect(store.snippets.count == BuiltinSnippets.load().count)
        #expect(try groups.allGroups().map(\.name) == BuiltinSnippets.loadGroupNames())
    }

    @Test("导入后命令按 id 关联到分组，无悬空 id")
    func importsLinkCommandsToGroupIDs() throws {
        let store = StubBuiltinSnippetRepository()
        let groups = StubBuiltinGroupRepository()

        try BuiltinSnippets.importIfNeeded(into: store, groups: groups)

        let systemGroupID = try #require(groups.allGroups().first { $0.name == "系统" }).id
        let overview = try #require(store.snippets.first { $0.title == "系统概览" })
        #expect(overview.groupIDs == [systemGroupID])
        let known = Set(try groups.allGroups().map(\.id))
        #expect(store.snippets.allSatisfy { $0.groupIDs.allSatisfy(known.contains) })
    }

    @Test("重复导入不新增也不覆盖用户编辑")
    func importIsIdempotentAndPreservesEdits() throws {
        let store = StubBuiltinSnippetRepository()
        let groups = StubBuiltinGroupRepository()
        try BuiltinSnippets.importIfNeeded(into: store, groups: groups)
        let count = store.snippets.count
        var edited = try #require(store.snippets.first)
        edited.title = "我的标题"
        try store.save(edited)

        store.catalogVersion = 0
        try BuiltinSnippets.importIfNeeded(into: store, groups: groups)

        #expect(store.snippets.count == count)
        #expect(store.snippets.first { $0.id == edited.id }?.title == "我的标题")
    }

    @Test("删除内置片段后目录升级不会恢复")
    func suppressedBuiltinDoesNotReturn() throws {
        let store = StubBuiltinSnippetRepository()
        let groups = StubBuiltinGroupRepository()
        try BuiltinSnippets.importIfNeeded(into: store, groups: groups)
        let removed = try #require(store.snippets.first { $0.builtinKey == "container-list" })
        try store.delete(id: removed.id)

        store.catalogVersion = 0
        try BuiltinSnippets.importIfNeeded(into: store, groups: groups)

        #expect(store.snippets.allSatisfy { $0.builtinKey != "container-list" })
        #expect(store.suppressedKeys.contains("container-list"))
    }

    @Test("旧导入标记只抑制原十条，仍补入 macOS 等价片段")
    func adoptsLegacyImportWithoutDuplicates() throws {
        let store = StubBuiltinSnippetRepository()
        let groups = StubBuiltinGroupRepository()

        try BuiltinSnippets.adoptLegacyImport(in: store)
        try BuiltinSnippets.importIfNeeded(into: store, groups: groups)

        #expect(store.snippets.allSatisfy { $0.platforms == [.macOS] })
        #expect(store.snippets.contains { $0.builtinKey == "system-overview-macos" })
        #expect(store.snippets.allSatisfy { $0.builtinKey != "system-overview-linux" })
    }

    @Test("每条都有标题与命令，排序权重递增")
    func wellFormed() {
        let snippets = BuiltinSnippets.load()
        #expect(snippets.allSatisfy { !$0.title.isEmpty && !$0.script.isEmpty })
        #expect(snippets.map(\.sortOrder) == Array(0 ..< snippets.count))
    }

    @Test("默认片段均为只读安全操作")
    func builtinsAreSafe() {
        let snippets = BuiltinSnippets.load()
        #expect(snippets.allSatisfy { !$0.danger })
    }

    @Test("含置顶片段")
    func hasPinned() {
        #expect(BuiltinSnippets.load().contains { $0.pinned })
    }

    @Test("变量片段可被 ConnKit 解析")
    func variablesParse() {
        let snippets = BuiltinSnippets.load()
        let variableSnippet = snippets.first { $0.script.contains("{{host") }
        #expect(variableSnippet != nil)
        #expect(variableSnippet?.variables.contains { $0.name == "host" } == true)
    }

    @Test("Docker 片段不把 Go 模板误判为变量")
    func dockerTemplatesNotVariables() {
        // 内置 docker 片段用 `docker ps -a`（无 {{json .}}），确保无误判变量
        let snippets = BuiltinSnippets.load()
        for snippet in snippets where snippet.script.hasPrefix("docker") {
            #expect(snippet.variables.allSatisfy { !$0.name.contains(".") })
        }
    }
}
