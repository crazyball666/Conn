import Foundation

/// 终端配色主题（技术方案 §4.2：内置 Dracula/Solarized 等）。
///
/// 与 UI 无关的纯数据，host 可测。SwiftTerm 桥接层把它转成 `Color`/`SwiftTerm.Color`。
public struct TerminalTheme: Sendable, Equatable, Identifiable {
    public struct RGB: Sendable, Equatable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }

        /// 从 `#RRGGBB` 解析。
        public init(hex: String) {
            let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            let value = UInt32(raw, radix: 16) ?? 0
            r = UInt8((value >> 16) & 0xFF)
            g = UInt8((value >> 8) & 0xFF)
            b = UInt8(value & 0xFF)
        }
    }

    public let id: String
    public let name: String
    public let background: RGB
    public let foreground: RGB
    public let cursor: RGB
    /// ANSI 16 色（0–7 标准，8–15 亮色）。
    public let ansi: [RGB]

    public init(id: String, name: String, background: RGB, foreground: RGB, cursor: RGB, ansi: [RGB]) {
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }
}

public extension TerminalTheme {
    /// 内置主题。Conn 默认用 `conn`（对齐设计规范 §2 的终端画布色）。
    static let all: [TerminalTheme] = [conn, dracula, solarizedDark]

    /// Conn 品牌终端主题：深空底 + 电光蓝紫光标（设计规范 connTermBg/connAccent）。
    static let conn = TerminalTheme(
        id: "conn", name: "Conn",
        background: RGB(hex: "07090F"),
        foreground: RGB(hex: "C6CCE0"),
        cursor: RGB(hex: "8B93FF"),
        ansi: [
            RGB(hex: "1F2437"), RGB(hex: "FF5C5C"), RGB(hex: "32D74B"), RGB(hex: "FFD60A"),
            RGB(hex: "8B93FF"), RGB(hex: "C77DFF"), RGB(hex: "5CD9FF"), RGB(hex: "C6CCE0"),
            RGB(hex: "5C6379"), RGB(hex: "FF8A8A"), RGB(hex: "6EE787"), RGB(hex: "FFE066"),
            RGB(hex: "B0B6FF"), RGB(hex: "DCA9FF"), RGB(hex: "8FE6FF"), RGB(hex: "EDEFF7")
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        background: RGB(hex: "282A36"),
        foreground: RGB(hex: "F8F8F2"),
        cursor: RGB(hex: "BD93F9"),
        ansi: [
            RGB(hex: "21222C"), RGB(hex: "FF5555"), RGB(hex: "50FA7B"), RGB(hex: "F1FA8C"),
            RGB(hex: "BD93F9"), RGB(hex: "FF79C6"), RGB(hex: "8BE9FD"), RGB(hex: "F8F8F2"),
            RGB(hex: "6272A4"), RGB(hex: "FF6E6E"), RGB(hex: "69FF94"), RGB(hex: "FFFFA5"),
            RGB(hex: "D6ACFF"), RGB(hex: "FF92DF"), RGB(hex: "A4FFFF"), RGB(hex: "FFFFFF")
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark",
        background: RGB(hex: "002B36"),
        foreground: RGB(hex: "839496"),
        cursor: RGB(hex: "93A1A1"),
        ansi: [
            RGB(hex: "073642"), RGB(hex: "DC322F"), RGB(hex: "859900"), RGB(hex: "B58900"),
            RGB(hex: "268BD2"), RGB(hex: "D33682"), RGB(hex: "2AA198"), RGB(hex: "EEE8D5"),
            RGB(hex: "002B36"), RGB(hex: "CB4B16"), RGB(hex: "586E75"), RGB(hex: "657B83"),
            RGB(hex: "839496"), RGB(hex: "6C71C4"), RGB(hex: "93A1A1"), RGB(hex: "FDF6E3")
        ]
    )
}
