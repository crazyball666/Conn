import XCTest

final class TerminalTmuxWindowNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSingleWindowSwipeShowsUnavailableWarningWithoutFalseSuccess() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        let expand = app.buttons["terminal.keybar.expand"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(expand.waitForExistence(timeout: 5))

        // Waiting for the provider tab proves that the persistent interaction facet and its
        // swipe descriptors have both reached the terminal controller.
        expand.tap()
        XCTAssertTrue(app.buttons["terminal.keybar.tab.tmux"].waitForExistence(timeout: 5))
        app.buttons["terminal.keybar.collapse"].tap()

        terminal.swipeLeft(velocity: .fast)

        let warning = app.descendants(matching: .any)["conn.toast.warning"].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertEqual(warning.label, "没有可切换的 Window")
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.success"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.error"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
