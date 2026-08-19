import Testing
@testable import ConnTerminal

@Suite("TerminalKeybarVisibilityPolicy — 快捷操作弹窗生命周期")
struct TerminalKeybarVisibilityPolicyTests {
    @Test("输入弹窗抢走终端焦点时快捷键栏仍留在视图层级")
    func providerActionPresentationKeepsKeybarAlive() {
        #expect(TerminalKeybarVisibilityPolicy.shouldShow(
            configurationShowsKeybar: true,
            terminalFocused: false,
            reviewActive: false,
            userPinned: false,
            providerActionPresented: true
        ))
    }

    @Test("关闭快捷键栏配置具有最高优先级")
    func disabledConfigurationAlwaysHidesKeybar() {
        #expect(!TerminalKeybarVisibilityPolicy.shouldShow(
            configurationShowsKeybar: false,
            terminalFocused: true,
            reviewActive: true,
            userPinned: true,
            providerActionPresented: true
        ))
    }
}
