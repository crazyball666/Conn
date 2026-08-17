import Foundation

/// 用户可选的终端光标形状；闪烁作为独立设置组合。
public enum TerminalCursorShape: String, CaseIterable, Identifiable, Sendable, Equatable {
    case block
    case bar
    case underline

    public var id: String { rawValue }
}

/// 传给 SwiftTerm 桥接层的完整显示与交互配置。
public struct TerminalConfiguration: Sendable, Equatable {
    public static let defaultFontSize: Double = 10

    public let theme: TerminalTheme
    public let fontSize: Double
    public let scrollback: Int
    public let cursorShape: TerminalCursorShape
    public let cursorBlinking: Bool
    public let showsKeybar: Bool

    public init(
        theme: TerminalTheme = .conn,
        fontSize: Double = TerminalConfiguration.defaultFontSize,
        scrollback: Int = 500,
        cursorShape: TerminalCursorShape = .block,
        cursorBlinking: Bool = true,
        showsKeybar: Bool = true
    ) {
        self.theme = theme
        self.fontSize = fontSize
        self.scrollback = scrollback
        self.cursorShape = cursorShape
        self.cursorBlinking = cursorBlinking
        self.showsKeybar = showsKeybar
    }
}
