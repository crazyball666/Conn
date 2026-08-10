import ConnKit
import Foundation

/// 内置模板库（方案 §4.6：JSON 资源，首启可跳过导入）。
public enum BuiltinSnippets {
    private struct LibraryDTO: Decodable {
        let version: Int
        let groups: [String]
        let commands: [CommandDTO]
    }

    private struct CommandDTO: Decodable {
        let key: String
        let title: String
        let script: String
        let groups: [String]
        let platforms: Set<RemotePlatformKind>?
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
        (decodeLibrary()?.groups ?? []).map { L($0) }
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
                platforms: dto.platforms ?? [],
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

        let existingGroups = try groupStore.allGroups()
        var idByName: [String: String] = [:]
        for (index, name) in loadGroupNames().enumerated() {
            let group: SnippetGroup
            if let existing = existingGroups.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                group = existing
            } else {
                group = SnippetGroup(name: name, sortOrder: index)
                try groupStore.save(group)
            }
            idByName[name] = group.id
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
                groupIDs: dto.groups.compactMap { idByName[L($0)] },
                pinned: dto.pinned ?? false,
                danger: dto.danger ?? false,
                platforms: dto.platforms ?? [],
                requiredCapabilities: dto.requiredCapabilities ?? [],
                builtinKey: dto.key,
                sortOrder: index
            ))
        }
        try store.setBuiltinCatalogVersion(library.version)
        return true
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
