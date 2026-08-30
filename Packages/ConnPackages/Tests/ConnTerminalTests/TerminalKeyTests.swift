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

    @Test("回车键发送 CR")
    func enterByte() {
        #expect(TerminalKey.enter.bytes == [0x0D])
        #expect(TerminalKey.enter.systemImageName == "return")
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

    @Test("移动键盘缺失的编辑与翻页键发送标准终端序列")
    func mobileEditingKeys() {
        #expect(TerminalKey.clearLine.bytes == [0x15])
        #expect(TerminalKey.clearLine.systemImageName == "eraser")
        #expect(TerminalKey.deleteForward.bytes == [0x1B, 0x5B, 0x33, 0x7E])
        #expect(TerminalKey.pageUp.bytes == [0x1B, 0x5B, 0x35, 0x7E])
        #expect(TerminalKey.pageDown.bytes == [0x1B, 0x5B, 0x36, 0x7E])
    }

    @Test("扩展面板控制组合发送对应控制码")
    func extendedControlKeys() {
        #expect(TerminalKey.backTab.bytes == [0x1B, 0x5B, 0x5A])
        #expect(TerminalKey.ctrlD.bytes == [0x04])
        #expect(TerminalKey.ctrlZ.bytes == [0x1A])
        #expect(TerminalKey.clearScreen.bytes == [0x0C])
        #expect(TerminalKey.lineStart.bytes == [0x01])
        #expect(TerminalKey.lineEnd.bytes == [0x05])
        #expect(TerminalKey.deleteWord.bytes == [0x17])
        #expect(TerminalKey.reverseSearch.bytes == [0x12])
        #expect(TerminalKey.historyPrevious.bytes == [0x10])
        #expect(TerminalKey.historyNext.bytes == [0x0E])
    }

    @Test("Insert 与 F1-F12 使用 xterm 标准序列")
    func functionKeys() {
        #expect(TerminalKey.insert.bytes == [0x1B, 0x5B, 0x32, 0x7E])
        #expect(TerminalKey.f1.bytes == [0x1B, 0x4F, 0x50])
        #expect(TerminalKey.f4.bytes == [0x1B, 0x4F, 0x53])
        #expect(TerminalKey.f5.bytes == [0x1B, 0x5B, 0x31, 0x35, 0x7E])
        #expect(TerminalKey.f10.bytes == [0x1B, 0x5B, 0x32, 0x31, 0x7E])
        #expect(TerminalKey.f12.bytes == [0x1B, 0x5B, 0x32, 0x34, 0x7E])
    }

    @Test("快捷栏紧凑态只保留高频控制键，其余移入常用面板")
    func mobileControlKeyLayout() {
        #expect(TerminalKeybarLayout.compactRows == [
            [
                .esc, .tab, .ctrl, .ctrlC, .clearLine, .enter
            ]
        ])
        #expect(TerminalKeybarLayout.compactKeys.count == 6)
        #expect(TerminalKeybarLayout.compactKeys.contains(.ctrlC))
        #expect(!TerminalKeybarLayout.compactKeys.contains(.ctrlD))
        #expect(!TerminalKeybarLayout.compactKeys.contains(.ctrlZ))
        #expect(!TerminalKeybarLayout.compactKeys.contains(.clearScreen))
        #expect(!TerminalKeybarLayout.compactKeys.contains(.deleteWord))
        #expect(TerminalKey.clearLine.systemImageName == "eraser")
        #expect(!TerminalKeybarLayout.expandedKeys.contains(.clearLine))
        #expect(TerminalKeybarLayout.expandedKeys.first == .ctrl)
        #expect(TerminalKeybarLayout.expandedKeys.contains(.ctrlD))
        #expect(TerminalKeybarLayout.expandedKeys.contains(.ctrlZ))
        #expect(TerminalKeybarLayout.expandedKeys.contains(.clearScreen))
        #expect(TerminalKeybarLayout.expandedKeys.contains(.backTab))
        #expect(TerminalKeybarLayout.expandedKeys.contains(.pageUp))
        #expect(TerminalKeybarLayout.expandedKeys.contains(.pageDown))
        #expect(TerminalKeybarLayout.expandedKeys.contains(.reverseSearch))
        #expect(TerminalKeybarLayout.expandedKeys.contains(.f1))
        #expect(TerminalKeybarLayout.expandedKeys.contains(.f12))
        #expect(Set(TerminalKeybarLayout.expandedKeys).count == TerminalKeybarLayout.expandedKeys.count)
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
