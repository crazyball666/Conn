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
    func testDockerTerminalFileBrowserStartsAtRemoteRoot() {
        let app = launchTerminal(
            subscription: "pro",
            reportsOSC7Directory: true,
            docker: true
        )
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 10))

        sessionActions.tap()
        let fileAction = app.buttons["terminal.session-actions.files"]
        XCTAssertTrue(fileAction.waitForExistence(timeout: 5))
        fileAction.tap()

        let browser = app.descendants(matching: .any)["terminal.file-browser"].firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["file-browser.breadcrumb.root"].firstMatch
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["file-browser.entry./home"].firstMatch
                .waitForExistence(timeout: 10)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["file-browser.breadcrumb./home"].firstMatch.exists,
            "Docker 终端的文件管理应从容器根目录开始"
        )
    }

    @MainActor
    func testTerminalFileBrowserStateIsolatedPerTerminalTab() {
        let app = launchTerminal(
            subscription: "pro",
            reportsOSC7Directory: true,
            secondTab: true
        )
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 10))

        sessionActions.tap()
        let fileAction = app.buttons["terminal.session-actions.files"]
        XCTAssertTrue(fileAction.waitForExistence(timeout: 5))
        fileAction.tap()
        let browser = app.descendants(matching: .any)["terminal.file-browser"].firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["file-browser.breadcrumb./home"].firstMatch
                .waitForExistence(timeout: 10)
        )
        app.descendants(matching: .any)["file-browser.entry./home/deploy"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["file-browser.breadcrumb./home/deploy"].firstMatch
                .waitForExistence(timeout: 5)
        )
        app.buttons["terminal.file-browser.close"].tap()
        XCTAssertTrue(browser.waitForNonExistence(timeout: 5))

        sessionActions.tap()
        let switchAction = app.buttons["terminal.session-actions.switch"]
        XCTAssertTrue(switchAction.waitForExistence(timeout: 5))
        switchAction.tap()

        let sessionRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.session.")
        )
        XCTAssertTrue(sessionRows.element(boundBy: 1).waitForExistence(timeout: 10))
        let firstSessionID = sessionRows.element(boundBy: 0).identifier
        let secondSessionID = sessionRows.element(boundBy: 1).identifier
        XCTAssertNotEqual(firstSessionID, secondSessionID)
        sessionRows.element(boundBy: 1).tap()

        sessionActions.tap()
        XCTAssertTrue(fileAction.waitForExistence(timeout: 5))
        fileAction.tap()
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["file-browser.breadcrumb.root"].firstMatch
                .waitForExistence(timeout: 10)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["file-browser.breadcrumb./home/deploy"].firstMatch.exists,
            "不同终端不应复用上一个终端的文件页面目录"
        )
        app.buttons["terminal.file-browser.close"].tap()
        XCTAssertTrue(browser.waitForNonExistence(timeout: 5))

        sessionActions.tap()
        XCTAssertTrue(switchAction.waitForExistence(timeout: 5))
        switchAction.tap()
        XCTAssertTrue(app.buttons[firstSessionID].waitForExistence(timeout: 10))
        app.buttons[firstSessionID].tap()

        sessionActions.tap()
        XCTAssertTrue(fileAction.waitForExistence(timeout: 5))
        fileAction.tap()
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["file-browser.breadcrumb./home/deploy"].firstMatch
                .waitForExistence(timeout: 10),
            "切回原终端后应恢复该终端自己的上次目录"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func launchTerminal(
        subscription: String,
        reportsOSC7Directory: Bool = false,
        docker: Bool = false,
        secondTab: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = subscription
        if reportsOSC7Directory {
            app.launchEnvironment["CONN_SMOKE_TERMINAL_OSC7"] = "1"
        }
        if docker {
            app.launchEnvironment["CONN_SMOKE_TERMINAL_DOCKER"] = "1"
        }
        if secondTab {
            app.launchEnvironment["CONN_SMOKE_TERMINAL_SECOND_TAB"] = "1"
        }
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()
        return app
    }
}
