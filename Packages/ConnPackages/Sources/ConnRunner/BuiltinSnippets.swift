import ConnKit
import Foundation

/// 内置模板库（方案 §4.6：JSON 资源，首启可跳过导入）。
public enum BuiltinSnippets {
    private struct LibraryDTO: Decodable {
        let groups: [String]
        let commands: [CommandDTO]
    }

    private struct CommandDTO: Decodable {
        let title: String
        let script: String
        let groups: [String]
        let interpreter: ShellInterpreter?
        let pinned: Bool?
        let danger: Bool?
    }

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
                sortOrder: index
            )
        }
    }

    /// 导入内置分组与命令。
    ///
    /// **是否需要导入由调用方判断**（`SettingsStore.builtinSnippetsImported`）——
    /// 改真删除后墓碑不存在，仓库无法再区分「从未导入」与「用户删光了」。
    @discardableResult
    public static func importIfNeeded(
        into store: any SnippetRepository,
        groups groupStore: any SnippetGroupRepository
    ) throws -> Bool {
        var idByName: [String: String] = [:]
        for (index, name) in loadGroupNames().enumerated() {
            let group = SnippetGroup(name: name, sortOrder: index)
            try groupStore.save(group)
            idByName[name] = group.id
        }
        for (index, dto) in (decodeLibrary()?.commands ?? []).enumerated() {
            try store.save(Snippet(
                title: L(dto.title),
                script: dto.script,
                interpreter: dto.interpreter ?? .sh,
                groupIDs: dto.groups.compactMap { idByName[L($0)] },
                pinned: dto.pinned ?? false,
                danger: dto.danger ?? false,
                sortOrder: index
            ))
        }
        return true
    }
}
