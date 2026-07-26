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
    static let all: [TerminalTheme] = [
        conn,
        dracula,
        solarizedDark,
        oneDark,
        nord,
        gruvboxDark,
        tokyoNight,
        catppuccinMocha,
    ]

    /// 按持久化 id 查找主题；旧值或异常值统一安全回退到 Conn。
    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? .conn
    }

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

    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark",
        background: RGB(hex: "282C34"),
        foreground: RGB(hex: "ABB2BF"),
        cursor: RGB(hex: "528BFF"),
        ansi: [
            RGB(hex: "1E2127"), RGB(hex: "E06C75"), RGB(hex: "98C379"), RGB(hex: "D19A66"),
            RGB(hex: "61AFEF"), RGB(hex: "C678DD"), RGB(hex: "56B6C2"), RGB(hex: "ABB2BF"),
            RGB(hex: "5C6370"), RGB(hex: "E06C75"), RGB(hex: "98C379"), RGB(hex: "D19A66"),
            RGB(hex: "61AFEF"), RGB(hex: "C678DD"), RGB(hex: "56B6C2"), RGB(hex: "FFFFFF")
        ]
    )

    static let nord = TerminalTheme(
        id: "nord", name: "Nord",
        background: RGB(hex: "2E3440"),
        foreground: RGB(hex: "D8DEE9"),
        cursor: RGB(hex: "88C0D0"),
        ansi: [
            RGB(hex: "3B4252"), RGB(hex: "BF616A"), RGB(hex: "A3BE8C"), RGB(hex: "EBCB8B"),
            RGB(hex: "81A1C1"), RGB(hex: "B48EAD"), RGB(hex: "88C0D0"), RGB(hex: "E5E9F0"),
            RGB(hex: "4C566A"), RGB(hex: "BF616A"), RGB(hex: "A3BE8C"), RGB(hex: "EBCB8B"),
            RGB(hex: "81A1C1"), RGB(hex: "B48EAD"), RGB(hex: "8FBCBB"), RGB(hex: "ECEFF4")
        ]
    )

    static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark", name: "Gruvbox Dark",
        background: RGB(hex: "282828"),
        foreground: RGB(hex: "EBDBB2"),
        cursor: RGB(hex: "FE8019"),
        ansi: [
            RGB(hex: "282828"), RGB(hex: "CC241D"), RGB(hex: "98971A"), RGB(hex: "D79921"),
            RGB(hex: "458588"), RGB(hex: "B16286"), RGB(hex: "689D6A"), RGB(hex: "A89984"),
            RGB(hex: "928374"), RGB(hex: "FB4934"), RGB(hex: "B8BB26"), RGB(hex: "FABD2F"),
            RGB(hex: "83A598"), RGB(hex: "D3869B"), RGB(hex: "8EC07C"), RGB(hex: "EBDBB2")
        ]
    )

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night",
        background: RGB(hex: "1A1B26"),
        foreground: RGB(hex: "C0CAF5"),
        cursor: RGB(hex: "C0CAF5"),
        ansi: [
            RGB(hex: "15161E"), RGB(hex: "F7768E"), RGB(hex: "9ECE6A"), RGB(hex: "E0AF68"),
            RGB(hex: "7AA2F7"), RGB(hex: "BB9AF7"), RGB(hex: "7DCFFF"), RGB(hex: "A9B1D6"),
            RGB(hex: "414868"), RGB(hex: "F7768E"), RGB(hex: "9ECE6A"), RGB(hex: "E0AF68"),
            RGB(hex: "7AA2F7"), RGB(hex: "BB9AF7"), RGB(hex: "7DCFFF"), RGB(hex: "C0CAF5")
        ]
    )

    static let catppuccinMocha = TerminalTheme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha",
        background: RGB(hex: "1E1E2E"),
        foreground: RGB(hex: "CDD6F4"),
        cursor: RGB(hex: "F5E0DC"),
        ansi: [
            RGB(hex: "45475A"), RGB(hex: "F38BA8"), RGB(hex: "A6E3A1"), RGB(hex: "F9E2AF"),
            RGB(hex: "89B4FA"), RGB(hex: "F5C2E7"), RGB(hex: "94E2D5"), RGB(hex: "BAC2DE"),
            RGB(hex: "585B70"), RGB(hex: "F38BA8"), RGB(hex: "A6E3A1"), RGB(hex: "F9E2AF"),
            RGB(hex: "89B4FA"), RGB(hex: "F5C2E7"), RGB(hex: "94E2D5"), RGB(hex: "A6ADC8")
        ]
    )
}
