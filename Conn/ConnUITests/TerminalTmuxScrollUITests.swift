import XCTest

final class TerminalTmuxScrollUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testVerticalSwipeUsesTmuxModeInsteadOfLocalHistoryReview() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_HISTORY"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        let expand = app.buttons["terminal.keybar.expand"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(expand.waitForExistence(timeout: 5))

        expand.tap()
        XCTAssertTrue(app.buttons["terminal.keybar.tab.tmux"].waitForExistence(timeout: 5))
        app.buttons["terminal.keybar.collapse"].tap()

        for _ in 0 ..< 4 {
            terminal.swipeDown(velocity: .fast)
            terminal.swipeUp(velocity: .fast)
        }

        terminal.tap()
        terminal.typeText("a")
        XCTAssertEqual(terminal.value as? String, "a")

        let review = app.descendants(matching: .any)["terminal.review.text"].firstMatch
        XCTAssertFalse(review.waitForExistence(timeout: 1))
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.warning"].firstMatch.exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["conn.toast.error"].firstMatch
                .waitForExistence(timeout: 1)
        )
        XCTAssertEqual(app.state, .runningForeground)
    }
}
