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

    private static func decodeDTOs() -> [DTO] {
        guard let url = Bundle.module.url(forResource: "builtin-snippets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dtos = try? JSONDecoder().decode([DTO].self, from: data)
        else { return [] }
        return dtos
    }

    /// 从打包 JSON 载入内置片段。标题/分组按**当前语言**本地化；排序权重按文件顺序。
    public static func load() -> [Snippet] {
        decodeDTOs().enumerated().map { index, dto in
            Snippet(
                title: L(dto.title),
                command: dto.command,
                folder: dto.folder.map { L($0) },
                pinned: dto.pinned ?? false,
                danger: dto.danger ?? false,
                sortOrder: index
            )
        }
    }

    /// 把已入库的、**未被用户改动**的内置片段的标题/分组更新到当前语言。
    ///
    /// 判定「未改动」：命令与某内置片段一致，且当前标题属于该内置标题的任一语言译文
    /// （用户自行改过标题的则跳过，不覆盖）。App 启动时调用即可跟随语言切换。
    public static func relocalize(in store: any SnippetRepository) {
        guard let stored = try? store.allSnippets(), !stored.isEmpty else { return }
        let byCommand = Dictionary(decodeDTOs().map { ($0.command, $0) }, uniquingKeysWith: { first, _ in first })

        for snippet in stored {
            guard let dto = byCommand[snippet.command] else { continue }
            var updated = snippet
            var changed = false
            // 标题：仅当仍等于某语言译文（未被用户改过）才更新到当前语言。
            if allLanguageVariants(dto.title).contains(snippet.title) {
                let localized = L(dto.title)
                if localized != snippet.title {
                    updated.title = localized
                    changed = true
                }
            }
            // 分组（#9）：仅当仍是内置默认分组时才更新；用户挪到自定义分组的不覆盖。
            if let folderKey = dto.folder, allLanguageVariants(folderKey).contains(snippet.folder ?? "") {
                let localized = L(folderKey)
                if localized != snippet.folder {
                    updated.folder = localized
                    changed = true
                }
            }
            if changed { try? store.save(updated) }
        }
    }
}
