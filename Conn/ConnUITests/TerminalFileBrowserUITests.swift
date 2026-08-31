import XCTest

final class TerminalFileBrowserUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testProTerminalFileBrowserRestoresDirectoryAfterDismissal() {
        let app = launchTerminal(subscription: "pro", reportsOSC7Directory: true)
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 10))

        sessionActions.tap()
        let fileAction = app.buttons["terminal.session-actions.files"]
        XCTAssertTrue(fileAction.waitForExistence(timeout: 5))
        XCTAssertTrue(fileAction.isHittable)
        fileAction.tap()

        let browser = app.descendants(matching: .any)["terminal.file-browser"].firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        let homeBreadcrumb = app.descendants(matching: .any)["file-browser.breadcrumb./home"].firstMatch
        XCTAssertTrue(homeBreadcrumb.waitForExistence(timeout: 5))
        let deploy = app.descendants(matching: .any)["file-browser.entry./home/deploy"].firstMatch
        XCTAssertTrue(deploy.waitForExistence(timeout: 10))
        deploy.tap()

        let deployBreadcrumb = app.descendants(matching: .any)["file-browser.breadcrumb./home/deploy"].firstMatch
        XCTAssertTrue(deployBreadcrumb.waitForExistence(timeout: 5))
        app.buttons["terminal.file-browser.close"].tap()
        XCTAssertTrue(browser.waitForNonExistence(timeout: 5))

        sessionActions.tap()
        XCTAssertTrue(fileAction.waitForExistence(timeout: 5))
        fileAction.tap()

        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["file-browser.breadcrumb./home"].firstMatch
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["file-browser.breadcrumb./home/deploy"].firstMatch
                .waitForExistence(timeout: 5),
            "同一个终端重新打开文件管理时应恢复上次目录"
        )
        XCTAssertTrue(app.state == .runningForeground)
    }

    @MainActor
    func testFreeTerminalFileBrowserEntryOpensExistingPaywall() {
        let app = launchTerminal(subscription: "free")
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 10))

        sessionActions.tap()
        let fileAction = app.buttons["terminal.session-actions.files"]
        XCTAssertTrue(fileAction.waitForExistence(timeout: 5))
        fileAction.tap()

        XCTAssertTrue(app.buttons["paywall.purchase"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["paywall"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["terminal.viewport"].firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func launchTerminal(
        subscription: String,
        reportsOSC7Directory: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = subscription
        if reportsOSC7Directory {
            app.launchEnvironment["CONN_SMOKE_TERMINAL_OSC7"] = "1"
        }
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()
        return app
    }
}
