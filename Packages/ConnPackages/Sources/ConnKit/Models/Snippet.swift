import Foundation

/// 可复用的 Shell 脚本片段。
///
/// 脚本中可含变量占位符 `{{name}}` 或 `{{name:默认值}}`，执行前由 UI 收集实参。
public struct Snippet: Identifiable, Codable, Sendable, Equatable {
    /// 一个变量占位符。
    public struct Variable: Sendable, Equatable, Hashable {
        public let name: String
        public let defaultValue: String?

        public init(name: String, defaultValue: String? = nil) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }

    public let id: String
    public var title: String
    /// 完整 Shell 脚本文本。单行内容也是合法脚本，不再单独区分命令类型。
    public var script: String
    /// 执行脚本时使用的解释器。
    public var interpreter: ShellInterpreter
    /// 脚本所属分组的 `SnippetGroup.id`。允许为空，也允许同时属于多个分组。
    public var groupIDs: [String]
    public var pinned: Bool
    /// 标记为危险片段。执行前强制二次确认；批量执行时需输入 `RUN`；
    /// App Intents 场景直接拒绝（技术实现方案 §4.6）。
    public var danger: Bool
    /// 执行前必须动态可用的能力，例如 Docker。空集合表示没有额外能力要求。
    public var requiredCapabilities: Set<RemoteCapability>
    /// 内置目录的稳定键。用户片段与 v1 遗留内置片段均为 nil。
    public var builtinKey: String?
    public var sortOrder: Int
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        script: String,
        interpreter: ShellInterpreter = .sh,
        groupIDs: [String] = [],
        pinned: Bool = false,
        danger: Bool = false,
        requiredCapabilities: Set<RemoteCapability> = [],
        builtinKey: String? = nil,
        sortOrder: Int = 0,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false
    ) {
        self.id = id
        self.title = title
        self.script = script
        self.interpreter = interpreter
        self.groupIDs = groupIDs
        self.pinned = pinned
        self.danger = danger
        self.requiredCapabilities = requiredCapabilities
        self.builtinKey = builtinKey
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, script, interpreter, groupIDs, pinned, danger
        case requiredCapabilities, builtinKey
        case sortOrder, createdAt, updatedAt, syncDirty
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        script = try values.decode(String.self, forKey: .script)
        interpreter = try values.decode(ShellInterpreter.self, forKey: .interpreter)
        groupIDs = try values.decode([String].self, forKey: .groupIDs)
        pinned = try values.decode(Bool.self, forKey: .pinned)
        danger = try values.decode(Bool.self, forKey: .danger)
        requiredCapabilities = try values.decodeIfPresent(
            Set<RemoteCapability>.self,
            forKey: .requiredCapabilities
        ) ?? []
        builtinKey = try values.decodeIfPresent(String.self, forKey: .builtinKey)
        sortOrder = try values.decode(Int.self, forKey: .sortOrder)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        updatedAt = try values.decode(Int64.self, forKey: .updatedAt)
        syncDirty = try values.decode(Bool.self, forKey: .syncDirty)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(script, forKey: .script)
        try values.encode(interpreter, forKey: .interpreter)
        try values.encode(groupIDs, forKey: .groupIDs)
        try values.encode(pinned, forKey: .pinned)
        try values.encode(danger, forKey: .danger)
        try values.encode(requiredCapabilities, forKey: .requiredCapabilities)
        try values.encodeIfPresent(builtinKey, forKey: .builtinKey)
        try values.encode(sortOrder, forKey: .sortOrder)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(syncDirty, forKey: .syncDirty)
    }

    /// 本片段脚本中声明的变量，按首次出现顺序去重。
    public var variables: [Variable] {
        Self.parseVariables(from: script)
    }

    /// 用实参填充脚本中的变量，得到可执行的最终脚本。
    ///
    /// 未提供实参的变量回退到默认值；无默认值则替换为空串。
    public func render(values: [String: String]) -> String {
        var result = script
        for variable in variables {
            let replacement = values[variable.name] ?? variable.defaultValue ?? ""
            // #22：用正则一次替换 {{name}} 与 {{name:任意默认值}} 两种写法——
            // 旧实现按 parseVariables 记住的默认值拼字面量,当同名变量先出现无默认形式时,
            // 带默认的那处会被漏替换、原样留进脚本。
            let escapedName = NSRegularExpression.escapedPattern(for: variable.name)
            let pattern = "\\{\\{\(escapedName)(?::[^}]*)?\\}\\}"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: replacement)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// 从脚本文本中解析变量占位符。
    ///
    /// 规则：
    /// - 变量名只允许 `[A-Za-z0-9_]`，因此 Docker 的 Go 模板 `{{json .}}`、
    ///   `{{.Names}}` 不会被误判为变量（含空格与点号）。这条很关键：内置
    ///   Docker 片段大量使用 Go 模板，误判会让用户被要求填写莫名其妙的参数。
    /// - 反斜杠转义的 `\{\{` 不参与匹配。
    /// - 同名变量只返回一次，保留首次出现时的默认值。
    public static func parseVariables(from script: String) -> [Variable] {
        // 先把转义序列替换为不可能出现在脚本里的哨兵字符，
        // 使 \{\{...\}\} 无法参与后续匹配
        let sanitized = script
            .replacingOccurrences(of: #"\{"#, with: "\u{0}")
            .replacingOccurrences(of: #"\}"#, with: "\u{0}")

        let pattern = #"\{\{([A-Za-z0-9_]+)(?::([^}]*))?\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(sanitized.startIndex..., in: sanitized)
        var seen = Set<String>()
        var result: [Variable] = []

        for match in regex.matches(in: sanitized, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: sanitized) else { continue }
            let name = String(sanitized[nameRange])
            guard seen.insert(name).inserted else { continue }

            var defaultValue: String?
            if match.range(at: 2).location != NSNotFound,
               let defaultRange = Range(match.range(at: 2), in: sanitized) {
                defaultValue = String(sanitized[defaultRange])
            }
            result.append(Variable(name: name, defaultValue: defaultValue))
        }
        return result
    }
}
