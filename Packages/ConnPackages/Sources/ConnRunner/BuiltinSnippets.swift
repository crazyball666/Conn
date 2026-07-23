import ConnKit
import Foundation

/// 内置模板库（方案 §4.6：JSON 资源，首启可跳过导入）。
public enum BuiltinSnippets {
    private struct DTO: Decodable {
        let title: String
        let command: String
        let folder: String?
        let pinned: Bool?
        let danger: Bool?
    }

    /// 从打包 JSON 载入内置片段。排序权重按文件顺序，保证展示稳定。
    public static func load() -> [Snippet] {
        guard let url = Bundle.module.url(forResource: "builtin-snippets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dtos = try? JSONDecoder().decode([DTO].self, from: data)
        else { return [] }

        return dtos.enumerated().map { index, dto in
            Snippet(
                title: dto.title,
                command: dto.command,
                folder: dto.folder,
                pinned: dto.pinned ?? false,
                danger: dto.danger ?? false,
                sortOrder: index
            )
        }
    }
}
