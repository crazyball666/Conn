import Foundation

/// 终端配色主题（技术方案 §4.2：内置 Dracula/Solarized 等）。
///
/// 与 UI 无关的纯数据，host 可测。SwiftTerm 桥接层把它转成 `Color`/`SwiftTerm.Color`。
public struct TerminalTheme: Sendable, Equatable, Identifiable {
    public enum Appearance: String, Sendable, Equatable, CaseIterable {
        case dark
        case light
    }

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
    public let appearance: Appearance
    public let background: RGB
    public let foreground: RGB
    public let cursor: RGB
    /// ANSI 16 色（0–7 标准，8–15 亮色）。
    public let ansi: [RGB]

    public init(
        id: String,
        name: String,
        appearance: Appearance,
        background: RGB,
        foreground: RGB,
        cursor: RGB,
        ansi: [RGB]
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
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
        monokai,
        githubDark,
        connLight,
        solarizedLight,
        gruvboxLight,
        oneLight,
        catppuccinLatte,
        githubLight,
    ]

    /// 按持久化 id 查找主题；旧值或异常值统一安全回退到 Conn。
    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? .conn
    }

    /// Conn 品牌终端主题：深空底 + 电光蓝紫光标（设计规范 connTermBg/connAccent）。
    static let conn = TerminalTheme(
        id: "conn", name: "Conn", appearance: .dark,
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
        id: "dracula", name: "Dracula", appearance: .dark,
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
        id: "solarized-dark", name: "Solarized Dark", appearance: .dark,
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
        id: "one-dark", name: "One Dark", appearance: .dark,
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
        id: "nord", name: "Nord", appearance: .dark,
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
        id: "gruvbox-dark", name: "Gruvbox Dark", appearance: .dark,
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
        id: "tokyo-night", name: "Tokyo Night", appearance: .dark,
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
        id: "catppuccin-mocha", name: "Catppuccin Mocha", appearance: .dark,
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

    /// Monokai：经典高饱和深色配色，适合长时间阅读代码和日志。
    static let monokai = TerminalTheme(
        id: "monokai", name: "Monokai", appearance: .dark,
        background: RGB(hex: "272822"),
        foreground: RGB(hex: "F8F8F2"),
        cursor: RGB(hex: "F8F8F0"),
        ansi: [
            RGB(hex: "272822"), RGB(hex: "F92672"), RGB(hex: "A6E22E"), RGB(hex: "FD971F"),
            RGB(hex: "66D9EF"), RGB(hex: "AE81FF"), RGB(hex: "A6E22E"), RGB(hex: "F8F8F2"),
            RGB(hex: "75715E"), RGB(hex: "F92672"), RGB(hex: "A6E22E"), RGB(hex: "E6DB74"),
            RGB(hex: "66D9EF"), RGB(hex: "AE81FF"), RGB(hex: "A6E22E"), RGB(hex: "F9F8F5")
        ]
    )

    /// GitHub Dark：GitHub 深色界面的中性底色与高辨识度语法色。
    static let githubDark = TerminalTheme(
        id: "github-dark", name: "GitHub Dark", appearance: .dark,
        background: RGB(hex: "0D1117"),
        foreground: RGB(hex: "C9D1D9"),
        cursor: RGB(hex: "58A6FF"),
        ansi: [
            RGB(hex: "484F58"), RGB(hex: "FF7B72"), RGB(hex: "7EE787"), RGB(hex: "D29922"),
            RGB(hex: "79C0FF"), RGB(hex: "D2A8FF"), RGB(hex: "A5D6FF"), RGB(hex: "B1BAC4"),
            RGB(hex: "6E7681"), RGB(hex: "FFA198"), RGB(hex: "56D364"), RGB(hex: "E3B341"),
            RGB(hex: "A5D6FF"), RGB(hex: "BC8CFF"), RGB(hex: "79C0FF"), RGB(hex: "F0F6FC")
        ]
    )

    static let connLight = TerminalTheme(
        id: "conn-light", name: "Conn Light", appearance: .light,
        background: RGB(hex: "F7F8FC"),
        foreground: RGB(hex: "25283A"),
        cursor: RGB(hex: "6C63FF"),
        ansi: [
            RGB(hex: "25283A"), RGB(hex: "D92D4F"), RGB(hex: "16835D"), RGB(hex: "9A6700"),
            RGB(hex: "3451D1"), RGB(hex: "7C3AED"), RGB(hex: "087E8B"), RGB(hex: "D9DDEA"),
            RGB(hex: "667085"), RGB(hex: "E5484D"), RGB(hex: "219B69"), RGB(hex: "B7791F"),
            RGB(hex: "4F67E8"), RGB(hex: "9355E8"), RGB(hex: "1696A7"), RGB(hex: "FFFFFF")
        ]
    )

    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", appearance: .light,
        background: RGB(hex: "FDF6E3"),
        foreground: RGB(hex: "586E75"),
        cursor: RGB(hex: "657B83"),
        ansi: [
            RGB(hex: "073642"), RGB(hex: "DC322F"), RGB(hex: "859900"), RGB(hex: "B58900"),
            RGB(hex: "268BD2"), RGB(hex: "D33682"), RGB(hex: "2AA198"), RGB(hex: "EEE8D5"),
            RGB(hex: "002B36"), RGB(hex: "CB4B16"), RGB(hex: "586E75"), RGB(hex: "657B83"),
            RGB(hex: "839496"), RGB(hex: "6C71C4"), RGB(hex: "93A1A1"), RGB(hex: "FDF6E3")
        ]
    )

    static let gruvboxLight = TerminalTheme(
        id: "gruvbox-light", name: "Gruvbox Light", appearance: .light,
        background: RGB(hex: "FBF1C7"),
        foreground: RGB(hex: "3C3836"),
        cursor: RGB(hex: "D65D0E"),
        ansi: [
            RGB(hex: "3C3836"), RGB(hex: "CC241D"), RGB(hex: "98971A"), RGB(hex: "D79921"),
            RGB(hex: "458588"), RGB(hex: "B16286"), RGB(hex: "689D6A"), RGB(hex: "7C6F64"),
            RGB(hex: "928374"), RGB(hex: "9D0006"), RGB(hex: "79740E"), RGB(hex: "B57614"),
            RGB(hex: "076678"), RGB(hex: "8F3F71"), RGB(hex: "427B58"), RGB(hex: "F9F5D7")
        ]
    )

    static let oneLight = TerminalTheme(
        id: "one-light", name: "One Light", appearance: .light,
        background: RGB(hex: "FAFAFA"),
        foreground: RGB(hex: "383A42"),
        cursor: RGB(hex: "526FFF"),
        ansi: [
            RGB(hex: "383A42"), RGB(hex: "E45649"), RGB(hex: "50A14F"), RGB(hex: "C18401"),
            RGB(hex: "4078F2"), RGB(hex: "A626A4"), RGB(hex: "0184BC"), RGB(hex: "A0A1A7"),
            RGB(hex: "696C77"), RGB(hex: "CA1243"), RGB(hex: "3F953A"), RGB(hex: "B76B01"),
            RGB(hex: "2F6FDB"), RGB(hex: "8E2A8C"), RGB(hex: "007FAD"), RGB(hex: "FFFFFF")
        ]
    )

    static let catppuccinLatte = TerminalTheme(
        id: "catppuccin-latte", name: "Catppuccin Latte", appearance: .light,
        background: RGB(hex: "EFF1F5"),
        foreground: RGB(hex: "4C4F69"),
        cursor: RGB(hex: "8839EF"),
        ansi: [
            RGB(hex: "5C5F77"), RGB(hex: "D20F39"), RGB(hex: "40A02B"), RGB(hex: "DF8E1D"),
            RGB(hex: "1E66F5"), RGB(hex: "EA76CB"), RGB(hex: "179299"), RGB(hex: "ACB0BE"),
            RGB(hex: "6C6F85"), RGB(hex: "D20F39"), RGB(hex: "40A02B"), RGB(hex: "DF8E1D"),
            RGB(hex: "1E66F5"), RGB(hex: "EA76CB"), RGB(hex: "179299"), RGB(hex: "BCC0CC")
        ]
    )

    /// GitHub Light：明亮、中性的浅色终端配色，降低大面积纯白带来的刺眼感。
    static let githubLight = TerminalTheme(
        id: "github-light", name: "GitHub Light", appearance: .light,
        background: RGB(hex: "F6F8FA"),
        foreground: RGB(hex: "24292F"),
        cursor: RGB(hex: "0969DA"),
        ansi: [
            RGB(hex: "24292F"), RGB(hex: "CF222E"), RGB(hex: "116329"), RGB(hex: "4D2D00"),
            RGB(hex: "0969DA"), RGB(hex: "8250DF"), RGB(hex: "1B7C83"), RGB(hex: "6E7781"),
            RGB(hex: "57606A"), RGB(hex: "A40E26"), RGB(hex: "1A7F37"), RGB(hex: "633C01"),
            RGB(hex: "218BFF"), RGB(hex: "A475F9"), RGB(hex: "3192AA"), RGB(hex: "8C959F")
        ]
    )
}
