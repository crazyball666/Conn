import ConnKit
import Foundation

/// 内置模板库（方案 §4.6：JSON 资源，首启可跳过导入）。
public enum BuiltinSnippets {
    private struct LibraryDTO: Decodable {
        let version: Int
        let groups: [GroupDTO]
        let commands: [CommandDTO]
    }

    private struct GroupDTO: Decodable {
        let key: String
        let title: String
        let legacyNames: [String]
    }

    private struct CommandDTO: Decodable {
        let key: String
        let title: String
        let script: String
        let groups: [String]
        let requiredCapabilities: Set<RemoteCapability>?
        let interpreter: ShellInterpreter?
        let pinned: Bool?
        let danger: Bool?
    }

    public static var catalogVersion: Int { decodeLibrary()?.version ?? 0 }

    private static func decodeLibrary() -> LibraryDTO? {
        guard let url = Bundle.module.url(forResource: "builtin-snippets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(LibraryDTO.self, from: data)
        else { return nil }
        return library
    }

    /// 从同一个内置 JSON 载入有序分组名。
    ///
    /// 名称在导入时按**当时**的语言定死一次，事后切语言不会重译——
    /// 与改造前行为一致。差别是成员匹配从「按本地化字符串」变成「按 id」，更稳。
    public static func loadGroupNames() -> [String] {
        (decodeLibrary()?.groups ?? []).map { L($0.title) }
    }

    /// 从打包 JSON 载入内置命令（不含分组归属，归属需要先建分组拿到 id）。
    ///
    /// 标题按当前语言本地化；排序权重按文件顺序。
    public static func load() -> [Snippet] {
        (decodeLibrary()?.commands ?? []).enumerated().map { index, dto in
            Snippet(
                title: L(dto.title),
                script: dto.script,
                interpreter: dto.interpreter ?? .sh,
                pinned: dto.pinned ?? false,
                danger: dto.danger ?? false,
                requiredCapabilities: dto.requiredCapabilities ?? [],
                builtinKey: dto.key,
                sortOrder: index
            )
        }
    }

    /// 导入内置分组与命令。
    ///
    /// 按稳定 key 幂等导入。已有记录视为用户可编辑数据，目录升级永不覆盖；
    /// suppression 中的 key 也不会被重新创建。
    @discardableResult
    public static func importIfNeeded(
        into store: any SnippetRepository,
        groups groupStore: any SnippetGroupRepository
    ) throws -> Bool {
        guard let library = decodeLibrary(),
              try store.builtinCatalogVersion() < library.version
        else { return false }

        var knownGroups = try groupStore.allGroups()
        let inferredGroupIDs = inferLegacyGroupIDs(
            library: library,
            snippets: try store.allSnippets(),
            knownGroupIDs: Set(knownGroups.map(\.id))
        )
        var idByKey: [String: String] = [:]
        for (index, dto) in library.groups.enumerated() {
            let localizedName = L(dto.title)
            var group: SnippetGroup
            if let existing = knownGroups.first(where: { $0.builtinKey == dto.key }) {
                group = existing
            } else if let inferredID = inferredGroupIDs[dto.key],
                      let existingIndex = knownGroups.firstIndex(where: {
                          $0.id == inferredID && $0.builtinKey == nil
                      }) {
                // v2 的分组本身没有稳定 key，但其中的内置片段已经有 builtinKey。
                // 取该类别内置片段成员关系的唯一交集，可在用户改过分组名称后仍
                // 精确认领原分组，并完整保留用户名称。
                group = knownGroups[existingIndex]
                group.builtinKey = dto.key
                try groupStore.save(group)
                knownGroups[existingIndex] = group
            } else if let existingIndex = knownGroups.firstIndex(where: { candidate in
                guard candidate.builtinKey == nil else { return false }
                return ([dto.title, localizedName] + dto.legacyNames).contains { name in
                    candidate.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                }
            }) {
                group = knownGroups[existingIndex]
                group.builtinKey = dto.key
                try groupStore.save(group)
                knownGroups[existingIndex] = group
            } else {
                group = SnippetGroup(
                    id: "builtin-group.\(dto.key)",
                    name: localizedName,
                    sortOrder: index,
                    builtinKey: dto.key
                )
                try groupStore.save(group)
                knownGroups.append(group)
            }
            idByKey[dto.key] = group.id
        }
        for (index, dto) in library.commands.enumerated() {
            guard try store.snippet(builtinKey: dto.key) == nil,
                  try !store.isBuiltinSuppressed(dto.key)
            else { continue }
            try store.save(Snippet(
                id: "builtin.\(dto.key)",
                title: L(dto.title),
                script: dto.script,
                interpreter: dto.interpreter ?? .sh,
                groupIDs: dto.groups.compactMap { idByKey[$0] },
                pinned: dto.pinned ?? false,
                danger: dto.danger ?? false,
                requiredCapabilities: dto.requiredCapabilities ?? [],
                builtinKey: dto.key,
                sortOrder: index
            ))
        }
        try store.setBuiltinCatalogVersion(library.version)
        return true
    }

    /// 从 v2 已有内置片段的成员关系推断原内置分组。只有全部可见成员的分组交集
    /// 恰好得到一个已存在分组时才认领；有歧义时退回名称匹配，避免误标用户分组。
    private static func inferLegacyGroupIDs(
        library: LibraryDTO,
        snippets: [Snippet],
        knownGroupIDs: Set<String>
    ) -> [String: String] {
        var snippetByBuiltinKey: [String: Snippet] = [:]
        for snippet in snippets {
            guard let key = snippet.builtinKey else { continue }
            snippetByBuiltinKey[key] = snippet
        }

        var result: [String: String] = [:]
        for group in library.groups {
            let memberships = library.commands
                .filter { $0.groups.contains(group.key) }
                .compactMap { snippetByBuiltinKey[$0.key] }
                .map { Set($0.groupIDs).intersection(knownGroupIDs) }
            guard var common = memberships.first else { continue }
            for membership in memberships.dropFirst() {
                common.formIntersection(membership)
            }
            if common.count == 1, let id = common.first {
                result[group.key] = id
            }
        }
        return result
    }

    /// 从旧 UserDefaults 一次性标记迁移：v1 已导入的十条命令没有稳定 key，不能按
    /// 标题/脚本反推所有权。将它们对应的 key 记为 suppression，避免生成重复项；
    /// macOS 新增等价项仍可由随后一次版本化导入补齐。
    public static func adoptLegacyImport(in store: any SnippetRepository) throws {
        for key in legacyBuiltinKeys {
            try store.suppressBuiltin(key)
        }
    }

    private static let legacyBuiltinKeys: Set<String> = [
        "system-overview-linux", "cpu-top-linux", "memory-top-linux",
        "service-status-linux", "disk-usage", "listening-ports-linux",
        "connectivity-test", "system-log-linux", "container-list", "container-stats",
    ]
}
