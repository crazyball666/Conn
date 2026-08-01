import Foundation

/// 加速键条上的一个键（技术方案 §4.2）。
///
/// 键位与其发送的字节序列。控制键（Ctrl）是粘滞态，不直接发字节而是改变
/// 下一次输入的编码，由 `TerminalKeyEncoder` 处理。
public enum TerminalKey: String, CaseIterable, Identifiable, Sendable {
    case esc, tab, ctrl
    /// 四个方向不再各占一个键帽，改由摇杆（`TerminalDirectionPad`）发出，
    /// 但字节定义仍在这里——摇杆只是换了触发方式，序列没变。
    case up, down, left, right
    case ctrlC, ctrlD, ctrlZ
    case home, end, insert
    case clearLine, clearScreen, deleteForward, deleteWord
    case lineStart, lineEnd, reverseSearch, historyPrevious, historyNext
    case pageUp, pageDown, backTab
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    public var id: String { rawValue }

    /// 键帽显示文字。
    public var label: String {
        switch self {
        case .esc: "Esc"
        case .tab: "Tab"
        case .ctrl: "Ctrl"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .ctrlC: "^C"
        case .ctrlD: "^D"
        case .ctrlZ: "^Z"
        case .home: "Home"
        case .end: "End"
        case .insert: "Ins"
        case .clearLine: "Clear"
        case .clearScreen: "^L"
        case .deleteForward: "Del"
        case .deleteWord: "^W"
        case .lineStart: "^A"
        case .lineEnd: "^E"
        case .reverseSearch: "^R"
        case .historyPrevious: "^P"
        case .historyNext: "^N"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .backTab: "⇧Tab"
        case .f1: "F1"
        case .f2: "F2"
        case .f3: "F3"
        case .f4: "F4"
        case .f5: "F5"
        case .f6: "F6"
        case .f7: "F7"
        case .f8: "F8"
        case .f9: "F9"
        case .f10: "F10"
        case .f11: "F11"
        case .f12: "F12"
        }
    }

    /// Ctrl 是粘滞键，不直接发字节。
    public var isSticky: Bool { self == .ctrl }

    /// 该键发送的字节。粘滞键返回空（由 encoder 处理组合）。
    public var bytes: [UInt8] {
        switch self {
        case .esc: [0x1B]
        case .tab: [0x09]
        case .ctrl: []
        // 方向键：ESC [ A/B/C/D（xterm 常规光标序列）
        case .up: [0x1B, 0x5B, 0x41]
        case .down: [0x1B, 0x5B, 0x42]
        case .right: [0x1B, 0x5B, 0x43]
        case .left: [0x1B, 0x5B, 0x44]
        // 中断。直接发控制码而不是走 Ctrl 粘滞——中断是终端里最高频的操作，
        // 不该要求「先点 Ctrl 再点 C」两次点击。
        case .ctrlC: [0x03]
        case .ctrlD: [0x04]
        case .ctrlZ: [0x1A]
        // 行首 / 行尾：ESC [ H 与 ESC [ F。TERM 是 xterm-256color，认这两条。
        case .home: [0x1B, 0x5B, 0x48]
        case .end: [0x1B, 0x5B, 0x46]
        case .insert: [0x1B, 0x5B, 0x32, 0x7E]
        // Readline / shell 常用控制组合。
        case .clearLine: [0x15]
        case .clearScreen: [0x0C]
        case .deleteForward: [0x1B, 0x5B, 0x33, 0x7E]
        case .deleteWord: [0x17]
        case .lineStart: [0x01]
        case .lineEnd: [0x05]
        case .reverseSearch: [0x12]
        case .historyPrevious: [0x10]
        case .historyNext: [0x0E]
        case .pageUp: [0x1B, 0x5B, 0x35, 0x7E]
        case .pageDown: [0x1B, 0x5B, 0x36, 0x7E]
        case .backTab: [0x1B, 0x5B, 0x5A]
        // xterm F1-F4 使用 SS3，F5-F12 使用 CSI ~ 序列。
        case .f1: [0x1B, 0x4F, 0x50]
        case .f2: [0x1B, 0x4F, 0x51]
        case .f3: [0x1B, 0x4F, 0x52]
        case .f4: [0x1B, 0x4F, 0x53]
        case .f5: [0x1B, 0x5B, 0x31, 0x35, 0x7E]
        case .f6: [0x1B, 0x5B, 0x31, 0x37, 0x7E]
        case .f7: [0x1B, 0x5B, 0x31, 0x38, 0x7E]
        case .f8: [0x1B, 0x5B, 0x31, 0x39, 0x7E]
        case .f9: [0x1B, 0x5B, 0x32, 0x30, 0x7E]
        case .f10: [0x1B, 0x5B, 0x32, 0x31, 0x7E]
        case .f11: [0x1B, 0x5B, 0x32, 0x33, 0x7E]
        case .f12: [0x1B, 0x5B, 0x32, 0x34, 0x7E]
        }
    }
}

/// 移动端快捷栏只保留系统键盘缺失或需要多步组合的控制键。
/// 普通字符（如 `/`、`|`、`~`）由系统键盘输入，不重复占用有限空间。
enum TerminalKeybarLayout {
    static let compactRows: [[TerminalKey]] = [
        [.esc, .tab, .ctrl, .ctrlC, .clearLine]
    ]

    /// 展开态按「导航编辑 → shell 控制 → 功能键」排列，普通可打印字符不重复出现。
    static let expandedKeys: [TerminalKey] = [
        .esc, .tab, .backTab, .up, .down, .left, .right,
        .home, .end, .insert, .deleteForward, .pageUp, .pageDown,
        .ctrlC, .ctrlD, .ctrlZ, .clearLine, .clearScreen,
        .lineStart, .lineEnd, .deleteWord, .reverseSearch, .historyPrevious, .historyNext,
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12
    ]
}

/// Ctrl 粘滞态的输入编码器。
///
/// Ctrl 点亮后，下一次输入的字符若为字母则转成 Ctrl 组合（`c & 0x1f`，
/// 如 Ctrl+C → 0x03），随后自动解除粘滞。
public struct TerminalKeyEncoder: Sendable {
    /// 编码一段用户输入。
    /// - Parameters:
    ///   - input: 原始输入字节（系统键盘或键条产生）。
    ///   - ctrlActive: Ctrl 粘滞是否激活。
    /// - Returns: 编码后的字节，以及处理后 Ctrl 是否仍激活（组合后解除）。
    public static func encode(_ input: [UInt8], ctrlActive: Bool) -> (bytes: [UInt8], ctrlStillActive: Bool) {
        guard ctrlActive, let first = input.first else {
            return (input, ctrlActive)
        }
        // Ctrl+字母：把首字节转成控制码，其余原样跟随；组合后解除粘滞
        let controlByte = first & 0x1F
        return ([controlByte] + input.dropFirst(), false)
    }
}
