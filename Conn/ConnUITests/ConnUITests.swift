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
        // 如果当前测试数据库已有活动终端，顺带验收快捷栏的真实布局；空数据库仍应
        // 至少完成终端主页导航，不人为注入远端凭据或终端会话。
        let directionPad = app.descendants(matching: .any)["terminal.keybar.directionPad"].firstMatch
        if directionPad.waitForExistence(timeout: 2) {
            let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
            XCTAssertTrue(keybar.exists)
            XCTAssertGreaterThanOrEqual(
                keybar.frame.maxX - directionPad.frame.maxX,
                8,
                "方向盘右侧应保留横向滑动安全间距"
            )
        }

        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        if sessionActions.waitForExistence(timeout: 2) {
            sessionActions.tap()
            let files = app.buttons["terminal.session-actions.files"]
            XCTAssertTrue(files.waitForExistence(timeout: 5))
            files.tap()
            XCTAssertTrue(
                app.otherElements["terminal.file-browser"].waitForExistence(timeout: 5)
            )
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testPaywallPresentsFocusedPlanSelection() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设置"].tap()

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        app.buttons["settings.pro"].tap()

        let paywall = app.otherElements["paywall"]
        XCTAssertTrue(paywall.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["paywall.hero"].exists)
        XCTAssertTrue(app.otherElements["paywall.features"].exists)
        XCTAssertTrue(app.otherElements["paywall.plans"].exists)
        XCTAssertTrue(app.buttons["paywall.plan.monthly"].exists)
        XCTAssertTrue(app.buttons["paywall.plan.yearly"].exists)
        XCTAssertTrue(app.buttons["paywall.purchase"].exists)
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testHostKeyMismatchConfirmationKeepsServerListStable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        let alert = app.alerts["确认更新主机指纹"]

        // 真实的指纹变更取决于服务器状态，不能在生产代码中植入测试开关。
        // 如果当前设备已有一台发生指纹变更的主机，验证完整的确认入口和取消路径；
        // 没有变更时仍验证列表和 App 进程保持稳定。
        if alert.waitForExistence(timeout: 5) {
            XCTAssertTrue(alert.buttons["更新指纹并重连"].exists)
            XCTAssertTrue(alert.buttons["取消"].exists)
            alert.buttons["取消"].tap()
            XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 5))
        }
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
