import Foundation

/// 日志行严重度（方案 §4.4：error/fail/panic/fatal 红、warn 黄）。
public enum LogLevel: String, Sendable, Equatable {
    case error, warn, normal
}

/// 日志行高亮判定。纯函数、host 可测；规则大小写不敏感。
public enum LogHighlighter {
    private static let errorTokens = ["error", "fail", "panic", "fatal", "exception"]
    private static let warnTokens = ["warn", "deprecated"]

    public static func level(for line: String) -> LogLevel {
        let lower = line.lowercased()
        if errorTokens.contains(where: lower.contains) { return .error }
        if warnTokens.contains(where: lower.contains) { return .warn }
        return .normal
    }
}

/// 一条日志行。`id` 为流内自增序号（去重与滚动定位用）。
public struct LogLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String
    public let level: LogLevel

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
        level = LogHighlighter.level(for: text)
    }
}
