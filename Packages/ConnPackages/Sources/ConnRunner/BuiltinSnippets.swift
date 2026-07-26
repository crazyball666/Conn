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

    /// 仅当仓库从未写入过命令时导入默认分组与命令。
    ///
    /// `totalCount` 包含软删除墓碑，因此用户删除默认命令后不会被再次补回。
    @discardableResult
    public static func importIfNeeded(into store: any SnippetRepository) throws -> Bool {
        guard try store.totalCount() == 0 else { return false }
        for folder in loadFolders() {
            try store.saveFolder(folder)
        }
        for snippet in load() {
            try store.save(snippet)
        }
        return true
    }
}
