import XCTest

final class KeyDeletionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyCanBeDeletedFromDetailWithSystemAlert() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_ME"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        let keyManager = app.staticTexts["密钥管理"]
        XCTAssertTrue(keyManager.waitForExistence(timeout: 5))
        keyManager.tap()
        XCTAssertTrue(app.navigationBars["密钥管理"].waitForExistence(timeout: 5))

        let generate = app.buttons.matching(NSPredicate(format: "label == '生成密钥'")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()
        let generateNavigationBar = app.navigationBars["生成密钥"]
        XCTAssertTrue(generateNavigationBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["密钥只保存在本地 Keychain"].waitForExistence(timeout: 5))
        generateNavigationBar.buttons["生成"].tap()

        let key = app.staticTexts["新密钥"]
        XCTAssertTrue(key.waitForExistence(timeout: 8))
        key.tap()
        XCTAssertTrue(app.navigationBars["新密钥"].waitForExistence(timeout: 5))

        let delete = app.buttons["key.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "密钥详情应提供明确删除入口")
        delete.tap()

        let alert = app.alerts["删除密钥"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(alert.textFields.firstMatch.exists)
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '永久删除' AND label CONTAINS '无法恢复'")
            ).firstMatch.exists
        )
        alert.buttons["删除"].tap()

        XCTAssertTrue(app.navigationBars["密钥管理"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["暂无密钥"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["新密钥"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
