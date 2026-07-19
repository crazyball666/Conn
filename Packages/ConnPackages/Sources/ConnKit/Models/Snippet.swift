import Foundation

/// 可复用的命令片段。
///
/// 命令中可含变量占位符 `{{name}}` 或 `{{name:默认值}}`，执行前由 UI 收集实参。
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
    public var command: String
    public var folder: String?
    public var pinned: Bool
    /// 标记为危险片段。执行前强制二次确认；批量执行时需输入 `RUN`；
    /// App Intents 场景直接拒绝（技术实现方案 §4.6）。
    public var danger: Bool
    public var sortOrder: Int
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool
    public var deletedAt: Int64?

    public init(
        id: String = UUID().uuidString,
        title: String,
        command: String,
        folder: String? = nil,
        pinned: Bool = false,
        danger: Bool = false,
        sortOrder: Int = 0,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.folder = folder
        self.pinned = pinned
        self.danger = danger
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
        self.deletedAt = deletedAt
    }

    /// 本片段命令中声明的变量，按首次出现顺序去重。
    public var variables: [Variable] {
        Self.parseVariables(from: command)
    }

    /// 用实参填充命令中的变量，得到可执行的最终命令。
    ///
    /// 未提供实参的变量回退到默认值；无默认值则替换为空串。
    public func render(values: [String: String]) -> String {
        var result = command
        for variable in variables {
            let replacement = values[variable.name] ?? variable.defaultValue ?? ""
            // 同时替换 {{name}} 与 {{name:default}} 两种写法
            let patterns = [
                "{{\(variable.name)}}",
                variable.defaultValue.map { "{{\(variable.name):\($0)}}" }
            ].compactMap { $0 }
            for pattern in patterns {
                result = result.replacingOccurrences(of: pattern, with: replacement)
            }
        }
        return result
    }

    /// 从命令文本中解析变量占位符。
    ///
    /// 规则：
    /// - 变量名只允许 `[A-Za-z0-9_]`，因此 Docker 的 Go 模板 `{{json .}}`、
    ///   `{{.Names}}` 不会被误判为变量（含空格与点号）。这条很关键：内置
    ///   Docker 片段大量使用 Go 模板，误判会让用户被要求填写莫名其妙的参数。
    /// - 反斜杠转义的 `\{\{` 不参与匹配。
    /// - 同名变量只返回一次，保留首次出现时的默认值。
    public static func parseVariables(from command: String) -> [Variable] {
        // 先把转义序列替换为不可能出现在命令里的哨兵字符，
        // 使 \{\{...\}\} 无法参与后续匹配
        let sanitized = command
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
