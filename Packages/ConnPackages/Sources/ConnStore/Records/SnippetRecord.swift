import ConnKit
import Foundation
import GRDB

/// `snippet` 表的 GRDB 记录。
struct SnippetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "snippet"

    var uuid: String
    var title: String
    var script: String
    var interpreter: ShellInterpreter
    var pinned: Bool
    var danger: Bool
    var requiredCapabilitiesJSON: String?
    var builtinKey: String?
    var sortOrder: Int
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool

    enum CodingKeys: String, CodingKey {
        case uuid, title, script, interpreter, pinned, danger
        case requiredCapabilitiesJSON = "required_capabilities_json"
        case builtinKey = "builtin_key"
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
        script = snippet.script
        interpreter = snippet.interpreter
        pinned = snippet.pinned
        danger = snippet.danger
        requiredCapabilitiesJSON = Self.encodeRawValues(snippet.requiredCapabilities)
        builtinKey = snippet.builtinKey
        sortOrder = snippet.sortOrder
        createdAt = snippet.createdAt
        updatedAt = snippet.updatedAt
        syncDirty = snippet.syncDirty
    }

    func toDomain(groupIDs: [String]) -> Snippet {
        Snippet(
            id: uuid,
            title: title,
            script: script,
            interpreter: interpreter,
            groupIDs: groupIDs,
            pinned: pinned,
            danger: danger,
            requiredCapabilities: Self.decodeRawValues(requiredCapabilitiesJSON),
            builtinKey: builtinKey,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }

    private static func encodeRawValues<Value: RawRepresentable>(_ values: Set<Value>) -> String?
    where Value.RawValue == String {
        guard !values.isEmpty else { return nil }
        let rawValues = values.map(\.rawValue).sorted()
        guard let data = try? JSONEncoder().encode(rawValues) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeRawValues<Value: RawRepresentable & Hashable>(
        _ json: String?
    ) -> Set<Value> where Value.RawValue == String {
        guard let json,
              let rawValues = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        else { return [] }
        return Set(rawValues.compactMap(Value.init(rawValue:)))
    }
}
