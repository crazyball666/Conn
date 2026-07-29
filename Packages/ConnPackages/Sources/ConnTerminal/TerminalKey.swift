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
    case ctrlC
    case slash, pipe, tilde
    case home, end

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
        case .slash: "/"
        case .pipe: "|"
        case .tilde: "~"
        case .home: "Home"
        case .end: "End"
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
        case .slash: Array("/".utf8)
        case .pipe: Array("|".utf8)
        case .tilde: Array("~".utf8)
        // 行首 / 行尾：ESC [ H 与 ESC [ F。TERM 是 xterm-256color，认这两条。
        case .home: [0x1B, 0x5B, 0x48]
        case .end: [0x1B, 0x5B, 0x46]
        }
    }
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
