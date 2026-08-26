import XCTest

final class TerminalTmuxRenameUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRenameSessionSavesWithOneTapWhileKeyboardIsVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let providerTab = app.buttons["terminal.keybar.tab.tmux"]
        XCTAssertTrue(providerTab.waitForExistence(timeout: 10))
        providerTab.tap()

        let rename = app.buttons["terminal.keybar.tmux.tmux.session.rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()

        let alert = app.alerts["重命名 Session"]
        let nameField = alert.textFields["Session 名称"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(alert.exists, "输入框抢走终端焦点后重命名弹窗不应自行关闭")
        XCTAssertTrue(nameField.exists)
        nameField.typeText("renamed-session")
        XCTAssertTrue(app.keyboards.firstMatch.exists)

        let save = alert.buttons["保存"]
        XCTAssertTrue(save.exists)
        save.tap()

        // Toast 从 action 成功时开始计时，而 Alert 退场动画还在进行。
        // 先观测短暂的 Toast，再等待 Alert 完全消失，避免把已执行成功
        // 且标题已更新的操作误判为失败。
        XCTAssertTrue(
            app.descendants(matching: .any)["conn.toast.success"].firstMatch
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        let terminalHeader = app.descendants(matching: .any)["terminal.header"]
        XCTAssertTrue(terminalHeader.waitForExistence(timeout: 5))
        let renamedTitle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "renamed-session"),
            object: terminalHeader
        )
        XCTAssertEqual(XCTWaiter.wait(for: [renamedTitle], timeout: 5), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.error"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testCloseWindowUsesSystemAlertConfirmation() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let providerTab = app.buttons["terminal.keybar.tab.tmux"]
        XCTAssertTrue(providerTab.waitForExistence(timeout: 10))
        providerTab.tap()

        let closeWindow = app.buttons["terminal.keybar.tmux.tmux.window.close"]
        XCTAssertTrue(closeWindow.waitForExistence(timeout: 5))
        closeWindow.tap()

        let alert = app.alerts["关闭当前 Window？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(alert.textFields.firstMatch.exists)
        XCTAssertTrue(alert.buttons["关闭 Window"].exists)
        XCTAssertTrue(alert.buttons["取消"].exists)
        alert.buttons["取消"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testClosePaneCompletesAfterKeyboardDrivenAlertResize() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        let keyboard = app.keyboards.firstMatch
        let expand = app.buttons["terminal.keybar.expand"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()

        let providerTab = app.buttons["terminal.keybar.tab.tmux"]
        XCTAssertTrue(providerTab.waitForExistence(timeout: 5))
        providerTab.tap()

        let closePane = app.buttons["terminal.keybar.tmux.tmux.pane.close"]
        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        XCTAssertTrue(closePane.waitForExistence(timeout: 5))
        for _ in 0 ..< 3 where !closePane.isHittable {
            keybar.swipeUp()
        }
        XCTAssertTrue(closePane.isHittable)
        closePane.tap()

        let alert = app.alerts["关闭当前 Pane？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let confirm = alert.buttons["关闭 Pane"]
        XCTAssertTrue(confirm.exists)
        confirm.tap()

        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.error"].exists)
        XCTAssertFalse(app.staticTexts["持久终端操作失败，请重试"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testRapidWindowAndPaneCreationUsesOneSerialQueue() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let providerTab = app.buttons["terminal.keybar.tab.tmux"]
        XCTAssertTrue(providerTab.waitForExistence(timeout: 10))
        providerTab.tap()

        let newWindow = app.buttons["terminal.keybar.tmux.tmux.window.new"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5))
        for _ in 0 ..< 4 { newWindow.tap() }

        let splitPane = app.buttons["terminal.keybar.tmux.tmux.pane.split-horizontal"]
        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        for _ in 0 ..< 4 where !splitPane.isHittable {
            keybar.swipeUp()
        }
        XCTAssertTrue(splitPane.waitForExistence(timeout: 5))
        XCTAssertTrue(splitPane.isHittable)
        for _ in 0 ..< 4 { splitPane.tap() }

        // The smoke provider deliberately takes 120 ms per action. Waiting longer than the
        // eight-command serial budget verifies that no stale-state failure interrupts the
        // queue while the App remains responsive.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.error"].exists)
        XCTAssertFalse(app.staticTexts["持久终端操作失败，请重试"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
