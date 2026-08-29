import XCTest

final class SnippetPlatformRemovalUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSelectingHostDoesNotRunCompatibilityCheck() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_SCRIPT_RUN"] = "1"
        app.launch()

        let hostPicker = app.staticTexts["选择主机或分组"]
        XCTAssertTrue(hostPicker.waitForExistence(timeout: 10))
        hostPicker.tap()

        let productionGroup = app.staticTexts["生产"]
        XCTAssertTrue(productionGroup.waitForExistence(timeout: 5))
        productionGroup.tap()

        let host = app.staticTexts["web-01"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()

        XCTAssertTrue(app.staticTexts["已选择 1 台主机"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["正在检查脚本兼容性…"].exists)
        XCTAssertTrue(app.buttons["执行脚本"].isEnabled)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testSnippetListHasNoPlatformBadges() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_SNIPPETS"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["脚本"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["系统"].exists)
        XCTAssertTrue(app.buttons["网络"].exists)
        XCTAssertFalse(app.buttons["磁盘"].exists)
        XCTAssertFalse(app.buttons["日志"].exists)
        XCTAssertFalse(app.buttons["Docker"].exists)
        XCTAssertFalse(app.staticTexts["macOS"].exists)
        XCTAssertFalse(app.staticTexts["Linux"].exists)
        XCTAssertFalse(app.staticTexts["Windows"].exists)
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "snippet.row.")
        )
        let firstRow = rows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(firstRow.frame.height, 58)
        let firstTitle = app.staticTexts["系统概览"].firstMatch
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 5))
        XCTAssertLessThan(firstTitle.frame.height, 20)

        app.buttons["全部"].tap()
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "系统概览")).count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "CPU 占用 Top 10")).count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "内存占用 Top 10")).count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "服务状态")).count, 1)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "sw_vers")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "launchctl")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["磁盘使用"].exists)
        XCTAssertFalse(app.staticTexts["系统日志尾部"].exists)
        XCTAssertFalse(app.staticTexts["容器列表"].exists)
        XCTAssertFalse(app.staticTexts["容器资源占用"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testRerunCentersLoadingAndImmediatelyHidesPreviousResult() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_SCRIPT_RUN"] = "1"
        app.launchEnvironment["CONN_SMOKE_EXEC_DELAY_MS"] = "800"
        app.launch()

        let hostPicker = app.staticTexts["选择主机或分组"]
        XCTAssertTrue(hostPicker.waitForExistence(timeout: 10))
        hostPicker.tap()
        let productionGroup = app.staticTexts["生产"]
        XCTAssertTrue(productionGroup.waitForExistence(timeout: 5))
        productionGroup.tap()
        let host = app.staticTexts["web-01"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()

        let execute = app.buttons["执行脚本"]
        XCTAssertTrue(execute.isEnabled)
        execute.tap()

        let progress = app.staticTexts["执行中…"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))

        let previousResult = app.staticTexts["执行结果"]
        XCTAssertTrue(previousResult.waitForExistence(timeout: 10))

        execute.tap()

        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertFalse(previousResult.exists)
        XCTAssertTrue(app.staticTexts["执行结果"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
