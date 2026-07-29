import Testing
@testable import ConnTerminal

@Suite("TerminalKey — 键位字节序列")
struct TerminalKeyTests {
    @Test("Esc 发 0x1b")
    func escByte() {
        #expect(TerminalKey.esc.bytes == [0x1B])
    }

    @Test("Tab 发 0x09")
    func tabByte() {
        #expect(TerminalKey.tab.bytes == [0x09])
    }

    @Test("方向键发 xterm 光标序列 ESC [ A/B/C/D")
    func arrowKeys() {
        #expect(TerminalKey.up.bytes == [0x1B, 0x5B, 0x41])
        #expect(TerminalKey.down.bytes == [0x1B, 0x5B, 0x42])
        #expect(TerminalKey.right.bytes == [0x1B, 0x5B, 0x43])
        #expect(TerminalKey.left.bytes == [0x1B, 0x5B, 0x44])
    }

    @Test("Ctrl 是粘滞键，不发字节")
    func ctrlIsSticky() {
        #expect(TerminalKey.ctrl.isSticky)
        #expect(TerminalKey.ctrl.bytes.isEmpty)
    }

    /// ^C 直接发控制码，不经 Ctrl 粘滞——中断是终端最高频操作，
    /// 不该要求「先点 Ctrl 再点 C」两次点击。
    @Test("^C 直接发 0x03，且不是粘滞键")
    func ctrlCByte() {
        #expect(TerminalKey.ctrlC.bytes == [0x03])
        #expect(!TerminalKey.ctrlC.isSticky)
    }

    @Test("Home / End 发 ESC [ H 与 ESC [ F")
    func homeEndKeys() {
        #expect(TerminalKey.home.bytes == [0x1B, 0x5B, 0x48])
        #expect(TerminalKey.end.bytes == [0x1B, 0x5B, 0x46])
    }

    @Test("字符键发对应 ASCII")
    func charKeys() {
        #expect(TerminalKey.pipe.bytes == [0x7C]) // |
        #expect(TerminalKey.tilde.bytes == [0x7E]) // ~
        #expect(TerminalKey.slash.bytes == [0x2F]) // /
    }
}

@Suite("TerminalKeyEncoder — Ctrl 粘滞组合")
struct TerminalKeyEncoderTests {
    @Test("Ctrl 未激活时原样透传")
    func passthroughWhenInactive() {
        let (bytes, active) = TerminalKeyEncoder.encode(Array("c".utf8), ctrlActive: false)
        #expect(bytes == Array("c".utf8))
        #expect(!active)
    }

    @Test("Ctrl+C → 0x03，并解除粘滞")
    func ctrlC() {
        let (bytes, active) = TerminalKeyEncoder.encode(Array("c".utf8), ctrlActive: true)
        #expect(bytes == [0x03])
        #expect(!active)
    }

    @Test("Ctrl+D → 0x04")
    func ctrlD() {
        let (bytes, _) = TerminalKeyEncoder.encode(Array("d".utf8), ctrlActive: true)
        #expect(bytes == [0x04])
    }

    @Test("Ctrl 大写字母同样映射（C 与 c 都 →0x03）")
    func ctrlUppercase() {
        let (lower, _) = TerminalKeyEncoder.encode(Array("c".utf8), ctrlActive: true)
        let (upper, _) = TerminalKeyEncoder.encode(Array("C".utf8), ctrlActive: true)
        #expect(lower == [0x03])
        #expect(upper == [0x03])
    }

    @Test("空输入时 Ctrl 保持激活")
    func emptyInputKeepsCtrl() {
        let (bytes, active) = TerminalKeyEncoder.encode([], ctrlActive: true)
        #expect(bytes.isEmpty)
        #expect(active)
    }
}
