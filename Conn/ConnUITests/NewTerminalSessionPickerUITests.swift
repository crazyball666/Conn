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
        XCTAssertFalse(app.staticTexts["启动独立远程 Shell"].exists)
        XCTAssertFalse(app.staticTexts["连接或创建可恢复的远程 Session"].exists)

        let tmux = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "tmux")
        ).firstMatch
        XCTAssertTrue(tmux.waitForExistence(timeout: 10))
        tmux.tap()

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
    }
}
