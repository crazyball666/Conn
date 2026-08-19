import XCTest

final class TerminalKeybarLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDirectionPadKeepsOriginalCompactSize() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        let directionPad = app.descendants(matching: .any)[
            "terminal.keybar.directionPad"
        ].firstMatch
        XCTAssertTrue(keybar.waitForExistence(timeout: 10))
        XCTAssertTrue(directionPad.waitForExistence(timeout: 5))

        XCTAssertEqual(directionPad.frame.width, 40, accuracy: 1)
        XCTAssertEqual(directionPad.frame.height, 40, accuracy: 1)
        XCTAssertLessThanOrEqual(directionPad.frame.maxX, keybar.frame.maxX + 1)
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Terminal compact direction pad"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testExpandedTmuxPanelShowsAnotherActionRowWithoutClipping() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        let providerTab = app.buttons["terminal.keybar.tab.tmux"]
        XCTAssertTrue(keybar.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(keybar.frame.height, 212)
        XCTAssertLessThanOrEqual(keybar.frame.height, 220)
        XCTAssertTrue(providerTab.waitForExistence(timeout: 5))
        providerTab.tap()

        let secondSectionLastAction = app.buttons[
            "terminal.keybar.tmux.tmux.window.close"
        ]
        XCTAssertTrue(secondSectionLastAction.waitForExistence(timeout: 5))
        XCTAssertTrue(secondSectionLastAction.isHittable)
        XCTAssertGreaterThanOrEqual(secondSectionLastAction.frame.minX, keybar.frame.minX - 1)
        XCTAssertLessThanOrEqual(secondSectionLastAction.frame.maxX, keybar.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(secondSectionLastAction.frame.minY, keybar.frame.minY - 1)
        XCTAssertLessThanOrEqual(secondSectionLastAction.frame.maxY, keybar.frame.maxY + 1)
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Expanded tmux keybar layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
