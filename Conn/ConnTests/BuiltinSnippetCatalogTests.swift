import ConnKit
import ConnRunner
import Testing

private final class AppBuiltinSnippetRepository: SnippetRepository, @unchecked Sendable {
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

private final class AppBuiltinSnippetGroupRepository: SnippetGroupRepository, @unchecked Sendable {
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

@Suite("Built-in snippet catalog")
struct BuiltinSnippetCatalogTests {
    @Test("catalog contains only system and network entries")
    func catalogContainsOnlySystemAndNetworkEntries() throws {
        let snippets = BuiltinSnippets.load()
        let keys = Set(try snippets.map { try #require($0.builtinKey) })

        #expect(snippets.count == 6)
        #expect(BuiltinSnippets.catalogVersion == 1)
        #expect(BuiltinSnippets.loadGroupNames().count == 2)
        #expect(keys.allSatisfy { !$0.hasSuffix("-macos") })
        #expect(!keys.contains("disk-usage"))
        #expect(!keys.contains("system-log-linux"))
        #expect(!keys.contains("system-log-macos"))
        #expect(!keys.contains("container-list"))
        #expect(!keys.contains("container-stats"))
        #expect(snippets.allSatisfy { !$0.script.hasPrefix("docker ") })
    }

    @Test("catalog upgrade retires built-ins without deleting user content")
    func catalogUpgradeRetiresBuiltinsWithoutDeletingUserContent() throws {
        let store = AppBuiltinSnippetRepository()
        let groups = AppBuiltinSnippetGroupRepository()
        store.catalogVersion = BuiltinSnippets.catalogVersion - 1
        store.snippets = [
            Snippet(
                id: "builtin.container-list",
                title: "container list",
                script: "docker ps -a",
                groupIDs: ["builtin-group.docker"],
                builtinKey: "container-list"
            ),
            Snippet(
                id: "custom",
                title: "custom",
                script: "echo custom",
                groupIDs: ["builtin-group.docker"]
            ),
        ]
        groups.groups = [SnippetGroup(
            id: "builtin-group.docker",
            name: "custom tools",
            builtinKey: "docker"
        )]

        #expect(try BuiltinSnippets.importIfNeeded(into: store, groups: groups))
        #expect(store.snippets.allSatisfy { $0.builtinKey != "container-list" })
        #expect(store.snippets.contains { $0.id == "custom" })
        let preservedGroup = try #require(groups.groups.first { $0.id == "builtin-group.docker" })
        #expect(preservedGroup.name == "custom tools")
        #expect(preservedGroup.builtinKey == nil)
        #expect(Set(groups.groups.compactMap(\.builtinKey)) == ["system", "network"])
    }
}
