import ConnKit
import Foundation

/// 内置模板库（方案 §4.6：JSON 资源，首启可跳过导入）。
public enum BuiltinSnippets {
    private struct LibraryDTO: Decodable {
        let folders: [String]
        let commands: [CommandDTO]
    }

    private struct CommandDTO: Decodable {
        let title: String
        let command: String
        let folders: [String]
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

    /// 从同一个内置 JSON 载入有序分组。
    public static func loadFolders() -> [String] {
        (decodeLibrary()?.folders ?? []).map { L($0) }
    }

    /// 从打包 JSON 载入内置命令。标题/分组按当前语言本地化；排序权重按文件顺序。
    public static func load() -> [Snippet] {
        (decodeLibrary()?.commands ?? []).enumerated().map { index, dto in
            Snippet(
                title: L(dto.title),
                command: dto.command,
                folders: dto.folders.map { L($0) },
                pinned: dto.pinned ?? false,
                danger: dto.danger ?? false,
                sortOrder: index
            )
        }
    }

    /// 导入内置分组与命令。
    ///
    /// **是否需要导入由调用方判断**（`SettingsStore.builtinSnippetsImported`）——
    /// 改真删除后墓碑不存在，无法再靠行数区分「从未导入」与「用户删光了」。
    @discardableResult
    public static func importIfNeeded(into store: any SnippetRepository) throws -> Bool {
        for folder in loadFolders() {
            try store.saveFolder(folder)
        }
        for snippet in load() {
            try store.save(snippet)
        }
        return true
    }
}
