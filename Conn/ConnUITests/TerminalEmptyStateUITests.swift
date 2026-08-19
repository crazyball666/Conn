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
        app.launch()

        let hostCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.host.")
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(hostCard.frame.height, 52)

        hostCard.tap()
        let terminalRow = app.staticTexts["普通终端"]
        XCTAssertTrue(terminalRow.waitForExistence(timeout: 5))
    }
}
