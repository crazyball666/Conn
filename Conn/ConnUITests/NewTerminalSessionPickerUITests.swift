import XCTest

final class NewTerminalSessionPickerUITests: XCTestCase {
    @MainActor
    func testSessionPickerShowsCreateBeforeExistingAndToolbarRefresh() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_NEW_TERMINAL_PICKER"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["普通终端"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["tmux"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["zellij"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["持久终端"].exists)
        XCTAssertFalse(app.staticTexts["启动独立远程 Shell"].exists)
        XCTAssertFalse(app.staticTexts["连接或创建可恢复的远程 Session"].exists)

        let tmux = app.buttons["new-terminal.provider.tmux"]
        let zellij = app.buttons["new-terminal.provider.zellij"]
        XCTAssertTrue(tmux.waitForExistence(timeout: 10))
        XCTAssertTrue(zellij.waitForExistence(timeout: 10))
        XCTAssertTrue(tmux.isEnabled)
        XCTAssertTrue(zellij.isEnabled)
        zellij.tap()

        let createHeader = app.staticTexts["创建 Session"]
        let existingHeader = app.staticTexts["连接现有 Session"]
        XCTAssertTrue(createHeader.waitForExistence(timeout: 10))
        XCTAssertTrue(existingHeader.waitForExistence(timeout: 10))
        XCTAssertLessThan(createHeader.frame.minY, existingHeader.frame.minY)

        XCTAssertTrue(app.textFields["Session 名称（可选）"].exists)
        XCTAssertTrue(app.buttons["创建并连接"].exists)
        XCTAssertTrue(app.buttons["new-terminal.refresh-sessions"].exists)

        app.buttons["new-terminal.refresh-sessions"].tap()
        XCTAssertTrue(createHeader.exists)
        XCTAssertTrue(existingHeader.exists)
        XCTAssertLessThan(createHeader.frame.minY, existingHeader.frame.minY)

        let sessionField = app.textFields["Session 名称（可选）"]
        sessionField.tap()
        sessionField.typeText("one-tap-session")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["创建并连接"].tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 3),
            "键盘显示时首次点击必须执行创建 action，不能只收起键盘"
        )
        XCTAssertTrue(
            createHeader.waitForNonExistence(timeout: 3),
            "创建按钮 action 应在同一次点击中离开 Session 选择页"
        )

        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testUnavailableProviderIsDisabledAndDoesNotOpenPlainTerminal() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_NEW_TERMINAL_PICKER"] = "1"
        app.launchEnvironment["CONN_SMOKE_UNAVAILABLE_PROVIDER"] = "zellij"
        app.launch()

        let zellij = app.buttons["new-terminal.provider.zellij"]
        XCTAssertTrue(zellij.waitForExistence(timeout: 10))
        XCTAssertFalse(zellij.isEnabled)
        XCTAssertTrue(app.staticTexts["不可用"].exists)
        XCTAssertTrue(app.staticTexts["普通终端"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["terminal.viewport"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
