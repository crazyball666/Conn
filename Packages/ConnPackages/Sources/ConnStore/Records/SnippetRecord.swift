import ConnKit
import Foundation
import GRDB

/// `snippet` 表的 GRDB 记录。
struct SnippetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "snippet"

    var uuid: String
    var title: String
    var command: String
    var folder: String?
    var pinned: Bool
    var danger: Bool
    var sortOrder: Int
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool
    var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case uuid, title, command, folder, pinned, danger
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
        case deletedAt = "deleted_at"
    }
}

extension SnippetRecord {
    init(_ snippet: Snippet) {
        uuid = snippet.id
        title = snippet.title
        command = snippet.command
        folder = snippet.folder
        pinned = snippet.pinned
        danger = snippet.danger
        sortOrder = snippet.sortOrder
        createdAt = snippet.createdAt
        updatedAt = snippet.updatedAt
        syncDirty = snippet.syncDirty
        deletedAt = snippet.deletedAt
    }

    func toDomain() -> Snippet {
        Snippet(
            id: uuid,
            title: title,
            command: command,
            folder: folder,
            pinned: pinned,
            danger: danger,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty,
            deletedAt: deletedAt
        )
    }
}
