import XCTest

final class ConnUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsServersTab() {
        let app = XCUIApplication()
        app.launch()

        let serversTab = app.tabBars.buttons["tab.servers"]
        XCTAssertTrue(serversTab.waitForExistence(timeout: 10))
        XCTAssertTrue(serversTab.isSelected)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testTerminalCenterOpensWithoutCrashing() {
        let app = XCUIApplication()
        // 该测试验收已授权时的文件管理入口；订阅拦截由下面的专用测试覆盖。
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "pro"
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        app.tabBars.buttons["tab.terminal"].tap()

        XCTAssertTrue(app.tabBars.buttons["tab.terminal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["tab.terminal"].isSelected)
        // 如果当前测试数据库已有活动终端，顺带验收快捷栏的真实布局；空数据库仍应
        // 至少完成终端主页导航，不人为注入远端凭据或终端会话。
        let directionPad = app.descendants(matching: .any)["terminal.keybar.directionPad"].firstMatch
        if directionPad.waitForExistence(timeout: 2) {
            let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
            XCTAssertTrue(keybar.exists)
            XCTAssertTrue(app.buttons["terminal.keybar.close-terminal"].exists)
            XCTAssertTrue(app.buttons["terminal.keybar.switch-session"].exists)
            XCTAssertTrue(app.buttons["terminal.keybar.file-management"].exists)
            XCTAssertTrue(app.buttons["terminal.keybar.commands"].exists)
            XCTAssertTrue(app.buttons["terminal.keybar.expand"].exists)
            XCTAssertTrue(app.buttons["terminal.keybar.dismissKeyboard"].exists)
            XCTAssertGreaterThanOrEqual(directionPad.frame.height, 40)
            XCTAssertFalse(app.buttons["terminal.keybar.session-actions"].exists)
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testConfiguredHostCanCreateActiveTerminalShortcutBar() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "pro"
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        let hostCard = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "servers.host.")
        ).firstMatch
        guard hostCard.waitForExistence(timeout: 5) else {
            throw XCTSkip("当前模拟器没有已保存的主机配置")
        }
        hostCard.tap()

        let openTerminal = app.buttons["host.open-terminal"]
        XCTAssertTrue(openTerminal.waitForExistence(timeout: 5))
        openTerminal.tap()

        let plainTerminal = app.buttons["new-terminal.provider.plain"]
        if plainTerminal.waitForExistence(timeout: 5) {
            plainTerminal.tap()
        }

        let keybar = app.descendants(matching: .any)["terminal.keybar"]
        XCTAssertTrue(keybar.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["terminal.keybar.close-terminal"].exists)
        XCTAssertTrue(app.buttons["terminal.keybar.expand"].exists)
        XCTAssertTrue(app.buttons["terminal.keybar.dismissKeyboard"].exists)

        app.buttons["terminal.keybar.close-terminal"].tap()
        XCTAssertTrue(keybar.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testFreeTerminalFileManagementPresentsPaywallDirectly() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "free"
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        app.tabBars.buttons["tab.terminal"].tap()

        let files = app.buttons["terminal.keybar.file-management"]
        guard files.waitForExistence(timeout: 5) else {
            throw XCTSkip("当前模拟器没有活动终端会话，无法验收文件管理的订阅拦截入口")
        }

        files.tap()

        let paywall = app.descendants(matching: .any)["paywall"].firstMatch
        XCTAssertTrue(paywall.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["paywall.context"].firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testPaywallPresentsFocusedPlanSelection() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "free"
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        app.tabBars.buttons["tab.me"].tap()

        XCTAssertTrue(app.tabBars.buttons["tab.me"].waitForExistence(timeout: 10))
        app.buttons["settings.pro"].tap()

        let paywall = app.descendants(matching: .any)["paywall"].firstMatch
        XCTAssertTrue(paywall.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["paywall.hero"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.features"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.plans"].firstMatch.exists)
        XCTAssertTrue(app.buttons["paywall.plan.monthly"].exists)
        XCTAssertTrue(app.buttons["paywall.plan.yearly"].exists)
        XCTAssertTrue(app.buttons["paywall.purchase"].exists)
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testActiveSubscriptionShowsManagementInsteadOfPurchase() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "pro"
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        app.tabBars.buttons["tab.me"].tap()
        XCTAssertTrue(app.buttons["settings.pro"].waitForExistence(timeout: 10))
        app.buttons["settings.pro"].tap()

        let paywall = app.descendants(matching: .any)["paywall"].firstMatch
        XCTAssertTrue(paywall.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["paywall.active"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["paywall.manage"].exists)
        XCTAssertFalse(app.buttons["paywall.purchase"].exists)
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testHostKeyMismatchConfirmationKeepsServerListStable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        let alert = app.alerts["确认更新主机指纹"]

        // 真实的指纹变更取决于服务器状态，不能在生产代码中植入测试开关。
        // 如果当前设备已有一台发生指纹变更的主机，验证完整的确认入口和取消路径；
        // 没有变更时仍验证列表和 App 进程保持稳定。
        if alert.waitForExistence(timeout: 5) {
            XCTAssertTrue(alert.buttons["更新指纹并重连"].exists)
            XCTAssertTrue(alert.buttons["取消"].exists)
            alert.buttons["取消"].tap()
            XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 5))
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

#if DEBUG && CONN_DISABLE_SUBSCRIPTION
    @MainActor
    func testDisabledSubscriptionBuildShowsProEntitlement() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        app.tabBars.buttons["tab.me"].tap()

        XCTAssertTrue(app.tabBars.buttons["tab.me"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["订阅已生效"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }
#endif

    @MainActor
    func testLiveDatabaseCanAddEditAndDeleteHostWithoutCrashing() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        app.buttons["servers.add"].tap()
        let addServer = app.buttons["servers.add-host"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 5))
        addServer.tap()

        XCTAssertTrue(app.descendants(matching: .any)["host-form"].waitForExistence(timeout: 5))
        let marker = "ui-save-\(UUID().uuidString.prefix(8))"
        let name = app.textFields["host-form.name"]
        let address = app.textFields["host-form.address"]
        let username = app.textFields["host-form.username"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(address.exists)
        XCTAssertTrue(username.exists)
        name.tap()
        name.typeText(marker)
        address.tap()
        address.typeText("203.0.113.10")
        username.tap()
        username.typeText("root")
        app.buttons["host-form.save"].tap()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        let hostCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", marker)
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 5))

        hostCard.press(forDuration: 1)
        let edit = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "servers.host.edit.")
        ).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["host-form"].waitForExistence(timeout: 5))
        app.buttons["host-form.save"].tap()

        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        XCTAssertTrue(hostCard.waitForExistence(timeout: 5))

        hostCard.press(forDuration: 1)
        let delete = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "servers.host.delete.")
        ).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let deleteConfirmation = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "servers.host.delete.confirm")
        ).firstMatch
        XCTAssertTrue(deleteConfirmation.waitForExistence(timeout: 5))
        deleteConfirmation.tap()
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
