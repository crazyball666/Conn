import XCTest

final class ConnUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsServersTab() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testTerminalCenterOpensWithoutCrashing() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        app.tabBars.buttons["终端"].tap()

        XCTAssertTrue(app.navigationBars["终端"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

#if CONN_DISABLE_SUBSCRIPTION
    @MainActor
    func testDisabledSubscriptionBuildShowsProEntitlement() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设置"].tap()

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["订阅已生效"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }
#endif

    @MainActor
    func testLiveDatabaseCanAddEditAndDeleteHostWithoutCrashing() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        app.buttons["新增"].tap()
        let addServer = app.buttons["新增主机"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 5))
        addServer.tap()

        XCTAssertTrue(app.navigationBars["添加主机"].waitForExistence(timeout: 5))
        let marker = "ui-save-\(UUID().uuidString.prefix(8))"
        let name = app.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "便于记忆，选填")
        ).firstMatch
        let address = app.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "example.com 或 10.0.0.1")
        ).firstMatch
        let username = app.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "root")
        ).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(address.exists)
        XCTAssertTrue(username.exists)
        name.tap()
        name.typeText(marker)
        address.tap()
        address.typeText("203.0.113.10")
        username.tap()
        username.typeText("root")
        app.navigationBars["添加主机"].buttons["保存"].tap()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        let hostCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", marker)
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 5))

        hostCard.press(forDuration: 1)
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.navigationBars["编辑主机"].waitForExistence(timeout: 5))
        app.navigationBars["编辑主机"].buttons["保存"].tap()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        XCTAssertTrue(hostCard.waitForExistence(timeout: 5))

        hostCard.press(forDuration: 1)
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5))
        app.buttons["删除"].tap()
        let alert = app.alerts["删除主机"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["删除"].tap()
        XCTAssertTrue(hostCard.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
