import XCTest

final class DockerDestructiveConfirmationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testImageDeletionUsesSystemAlertWithoutTextEntry() throws {
        let app = launchDocker(tab: "images")

        let image = app.staticTexts["nginx:1.25"]
        XCTAssertTrue(image.waitForExistence(timeout: 8), "演示镜像应出现在列表")
        image.tap()

        XCTAssertTrue(app.navigationBars["nginx:1.25"].waitForExistence(timeout: 4))
        let delete = app.buttons.matching(NSPredicate(format: "label == '删除'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()

        assertTextFreeAlert(app, title: "删除镜像", target: "nginx:1.25")
        app.alerts["删除镜像"].buttons["取消"].tap()
        XCTAssertTrue(app.alerts["删除镜像"].waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testImageAndSystemPruneUseAlertsWhileSystemOptionsArePreserved() throws {
        let app = launchDocker(tab: "images")

        openMoreMenu(app, action: "清理悬空镜像")
        assertTextFreeAlert(app, title: "清理悬空镜像")
        app.alerts["清理悬空镜像"].buttons["取消"].tap()

        openMoreMenu(app, action: "清理 Docker 资源")
        XCTAssertTrue(app.navigationBars["清理 Docker 资源"].waitForExistence(timeout: 4))

        let allImages = app.switches["移除所有未使用镜像"]
        let volumes = app.switches["包含未使用卷"]
        XCTAssertTrue(allImages.waitForExistence(timeout: 2))
        XCTAssertTrue(volumes.waitForExistence(timeout: 2))
        turnOn(allImages)
        turnOn(volumes)
        app.buttons["继续"].tap()

        assertTextFreeAlert(app, title: "清理 Docker 资源")
        let alert = app.alerts["清理 Docker 资源"]
        XCTAssertTrue(
            alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '移除所有未使用镜像'"))
                .firstMatch.exists,
            "Alert 应复述用户选择的镜像清理范围"
        )
        XCTAssertTrue(
            alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '包含未使用卷'"))
                .firstMatch.exists,
            "Alert 应复述用户选择的卷清理范围"
        )
        alert.buttons["取消"].tap()
    }

    @MainActor
    private func turnOn(
        _ toggle: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // XCUI 暴露的 Toggle value 是字符串 "0" / "1"，不是 NSNumber。
        let isOn = NSPredicate(format: "value == '1'")
        if !isOn.evaluate(with: toggle) {
            // iOS 26 的 Form Toggle 无障碍 frame 覆盖整行，`tap()` 会落在文字区；
            // 点击右侧开关位置才等同于用户真实操作。
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let expectation = XCTNSPredicateExpectation(predicate: isOn, object: toggle)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 2),
            .completed,
            "应成功打开 \(toggle.label)",
            file: file,
            line: line
        )
    }

    @MainActor
    func testComposeDownUsesSystemAlertWithoutProjectNameEntry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_DETAIL"] = "1"
        app.launchEnvironment["CONN_SMOKE_SEGMENT"] = "docker"
        app.launchEnvironment["CONN_SMOKE_DOCKER_TAB"] = "compose"
        app.launchEnvironment["CONN_SMOKE_COMPOSE_DETAIL_ROUTE"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["conn-web"].waitForExistence(timeout: 10))
        let down = app.buttons.matching(NSPredicate(format: "label == '停止并移除'")).firstMatch
        XCTAssertTrue(down.waitForExistence(timeout: 4))
        down.tap()

        assertTextFreeAlert(app, title: "停止并移除 Compose 项目", target: "conn-web")
        app.alerts["停止并移除 Compose 项目"].buttons["取消"].tap()
    }

    @MainActor
    private func launchDocker(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_DETAIL"] = "1"
        app.launchEnvironment["CONN_SMOKE_SEGMENT"] = "docker"
        app.launchEnvironment["CONN_SMOKE_DOCKER_TAB"] = tab
        app.launch()
        return app
    }

    @MainActor
    private func openMoreMenu(_ app: XCUIApplication, action: String) {
        let menu = app.buttons["更多操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let item = app.buttons.matching(NSPredicate(format: "label == %@", action)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }

    @MainActor
    private func assertTextFreeAlert(
        _ app: XCUIApplication,
        title: String,
        target: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let alert = app.alerts[title]
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "应显示系统 Alert：\(title)", file: file, line: line)
        XCTAssertFalse(alert.textFields.firstMatch.exists, "Alert 不应要求手动输入确认词", file: file, line: line)
        XCTAssertTrue(alert.buttons["取消"].exists, file: file, line: line)
        if let target {
            XCTAssertTrue(
                alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", target)).firstMatch.exists,
                "Alert 应明确展示操作目标",
                file: file,
                line: line
            )
        }
    }
}
