import XCTest

final class SubscriptionPaywallUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFreeSettingsEntryOpensSubscriptionPaywall() {
        let app = launchDemo(environment: ["CONN_SMOKE_ME": "1"])

        let upgrade = app.buttons["settings.pro"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10))
        upgrade.tap()

        XCTAssertTrue(app.buttons["paywall.purchase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["paywall.plan.monthly"].exists)
        XCTAssertTrue(app.buttons["paywall.plan.yearly"].exists)
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        XCTAssertTrue(app.staticTexts["升级到 Conn Pro"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testFreeHostLimitOpensThirdHostPaywall() {
        let app = launchDemo()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        app.buttons["新增"].tap()
        XCTAssertTrue(app.buttons["新增主机"].waitForExistence(timeout: 3))
        app.buttons["新增主机"].tap()

        XCTAssertTrue(app.buttons["paywall.purchase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["添加第三台主机"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testFreeFileEntryOpensFileManagementPaywall() {
        let app = launchDemo(environment: [
            "CONN_SMOKE_DETAIL": "1",
            "CONN_SMOKE_SEGMENT": "files",
        ])

        XCTAssertTrue(app.buttons["paywall.purchase"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["文件管理"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testFreeDockerEntryOpensDockerManagementPaywall() {
        let app = launchDemo(environment: [
            "CONN_SMOKE_DETAIL": "1",
            "CONN_SMOKE_SEGMENT": "docker",
        ])

        XCTAssertTrue(app.buttons["paywall.purchase"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Docker 管理"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testFreeProcessEntryRemainsAvailable() {
        let app = launchDemo(environment: [
            "CONN_SMOKE_DETAIL": "1",
            "CONN_SMOKE_SEGMENT": "processes",
        ])

        XCTAssertTrue(app.navigationBars["进程"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["paywall.purchase"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testFreeLogEntryRemainsAvailable() {
        let app = launchDemo(environment: [
            "CONN_SMOKE_DETAIL": "1",
            "CONN_SMOKE_SEGMENT": "logs",
        ])

        XCTAssertTrue(app.navigationBars["日志"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["paywall.purchase"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testProFileEntryRemainsAvailable() {
        let app = launchDemo(
            environment: [
                "CONN_SMOKE_DETAIL": "1",
                "CONN_SMOKE_SEGMENT": "files",
                "CONN_SUBSCRIPTION_STATE": "pro",
            ]
        )

        XCTAssertTrue(app.navigationBars["文件"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["paywall.purchase"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func launchDemo(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "free"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }
}
