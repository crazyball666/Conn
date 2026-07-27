import ConnKit
import Foundation
import GRDB

/// `snippet` 表的 GRDB 记录。
struct SnippetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "snippet"

    var uuid: String
    var title: String
    var command: String
    var pinned: Bool
    var danger: Bool
    var sortOrder: Int
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool

    enum CodingKeys: String, CodingKey {
        case uuid, title, command, pinned, danger
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
    }
}

extension SnippetRecord {
    init(_ snippet: Snippet) {
        uuid = snippet.id
        title = snippet.title
        command = snippet.command
        pinned = snippet.pinned
        danger = snippet.danger
        sortOrder = snippet.sortOrder
        createdAt = snippet.createdAt
        updatedAt = snippet.updatedAt
        syncDirty = snippet.syncDirty
    }

    func toDomain(groupIDs: [String]) -> Snippet {
        Snippet(
            id: uuid,
            title: title,
            command: command,
            groupIDs: groupIDs,
            pinned: pinned,
            danger: danger,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }
}
