import XCTest

final class TerminalEmptyStateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyStateKeepsOnlyTitleAndToolbarCreationEntry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launch()

        let terminalTab = app.tabBars.buttons["终端"]
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 10))
        terminalTab.tap()

        XCTAssertTrue(app.staticTexts["暂无终端"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["新建普通终端或 tmux 终端后，会显示在这里。"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "新建终端").count, 1)
    }

    @MainActor
    func testTerminalHostCardUsesComfortableCompactHeightAndRemainsExpandable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_CENTER"] = "1"
        app.launchArguments += ["-conn.settings.appearance", "light"]
        app.launch()

        let hostCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.host.")
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(hostCard.frame.height, 52)

        hostCard.tap()
        let terminalRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.session.")
        ).firstMatch
        XCTAssertTrue(terminalRow.waitForExistence(timeout: 5))
        XCTAssertEqual(hostCard.frame.minX, terminalRow.frame.minX, accuracy: 1)
        XCTAssertEqual(hostCard.frame.width, terminalRow.frame.width, accuracy: 1)
        // 两行共享同一个 Section 背景；这里只允许标准行内留白，不能再嵌套独立卡片。
        XCTAssertLessThanOrEqual(terminalRow.frame.minY - hostCard.frame.maxY, 17)
        XCTAssertGreaterThanOrEqual(terminalRow.frame.height, 44)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Terminal center expanded card"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        terminalRow.swipeLeft()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 3))
    }
}
