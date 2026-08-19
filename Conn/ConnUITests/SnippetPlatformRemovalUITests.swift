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
        XCTAssertFalse(app.staticTexts["macOS"].exists)
        XCTAssertFalse(app.staticTexts["Linux"].exists)
        XCTAssertFalse(app.staticTexts["Windows"].exists)
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "snippet.row.")
        )
        let firstRow = rows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(firstRow.frame.height, 58)
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
