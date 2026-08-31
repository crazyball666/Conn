import XCTest

final class TerminalEmptyStateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyStateKeepsOnlyTitleAndToolbarCreationEntry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launch()

        let terminalTab = app.tabBars.buttons["终端"]
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 10))
        terminalTab.tap()

        XCTAssertTrue(app.staticTexts["暂无终端"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["新建普通终端或 tmux 终端后，会显示在这里。"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "新建终端").count, 1)
    }

    @MainActor
    func testTerminalHostCardUsesComfortableCompactHeightAndRemainsExpandable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_CENTER"] = "1"
        app.launchArguments += ["-conn.settings.appearance", "light"]
        app.launch()

        let hostCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.host.")
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(hostCard.frame.height, 52)

        hostCard.tap()
        let terminalRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.session.")
        ).firstMatch
        XCTAssertTrue(terminalRow.waitForExistence(timeout: 5))
        XCTAssertEqual(hostCard.frame.minX, terminalRow.frame.minX, accuracy: 1)
        XCTAssertEqual(hostCard.frame.width, terminalRow.frame.width, accuracy: 1)
        // 两行共享同一个 Section 背景；这里只允许标准行内留白，不能再嵌套独立卡片。
        XCTAssertLessThanOrEqual(terminalRow.frame.minY - hostCard.frame.maxY, 17)
        XCTAssertGreaterThanOrEqual(terminalRow.frame.height, 44)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Terminal center expanded card"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        terminalRow.swipeLeft()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCreatingPlainTerminalFromCenterOpensWithoutMissingSettingsEnvironment() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "false"]
        app.launch()

        let terminalTab = app.tabBars.buttons["终端"]
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 10))
        terminalTab.tap()
        let newTerminal = app.buttons["新建终端"].firstMatch
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 5))
        newTerminal.tap()

        let host = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "web-01")
        ).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()

        let plainTerminal = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "普通终端")
        ).firstMatch
        XCTAssertTrue(plainTerminal.waitForExistence(timeout: 5))
        plainTerminal.tap()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))

        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 5))
        sessionActions.tap()
        XCTAssertFalse(app.buttons["terminal.session-actions.return"].exists)
        let closePage = app.buttons["terminal.session-actions.close"]
        XCTAssertTrue(closePage.waitForExistence(timeout: 5))
        closePage.tap()

        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5))
        let hostCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.host.")
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 5))
        hostCard.tap()
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "terminal.session.")
            ).firstMatch.waitForExistence(timeout: 5),
            "关闭终端页面后，本地会话应继续保留在终端列表中"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testReconnectKeepsTerminalPageAndLocalSessionRecord() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_RECONNECT"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "false"]
        app.launch()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.smoke.reconnect.completed"].firstMatch
                .waitForExistence(timeout: 10),
            "重连应完成而不是关闭终端页面"
        )
        XCTAssertTrue(terminal.exists)
        XCTAssertEqual(app.state, .runningForeground)

        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 5))
        sessionActions.tap()
        let switchTerminal = app.buttons["terminal.session-actions.switch"]
        XCTAssertTrue(switchTerminal.waitForExistence(timeout: 5))
        switchTerminal.tap()

        XCTAssertTrue(app.navigationBars["终端会话"].waitForExistence(timeout: 5))
        let localSession = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "普通终端")
        ).firstMatch
        XCTAssertTrue(localSession.waitForExistence(timeout: 5), "重连后本地终端记录应继续存在")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testPersistedTmuxEntryRestoresWithoutOpeningWorkspacePicker() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_CENTER"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_RESUME"] = "1"
        // A blinking terminal cursor keeps XCTest's animation-idle detector busy.
        // The behavior under test is restoration, so use the supported steady-cursor setting.
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "false"]
        app.launch()

        let hostCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.host.")
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 15))
        hostCard.tap()

        let resume = app.buttons["terminal.resume.smoke-resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["saved-session"].exists)
        XCTAssertTrue(app.staticTexts["可恢复"].exists)

        let listScreenshot = XCTAttachment(screenshot: app.screenshot())
        listScreenshot.name = "Persisted terminal in local terminal list"
        listScreenshot.lifetime = .keepAlways
        add(listScreenshot)

        resume.tap()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 5))
        sessionActions.tap()
        let current = app.descendants(matching: .any)["terminal.session-actions.current"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.label.contains("saved-session"))
        XCTAssertFalse(app.staticTexts["选择持久终端"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Restored persistent terminal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testMissingPersistedTmuxEntryCanCreateReplacementSession() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_CENTER"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_RESUME"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_RESUME_MISSING"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_REPLACEMENT_DELAY"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "false"]
        app.launch()

        let hostCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.host.")
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 15))
        hostCard.tap()

        let resume = app.buttons["terminal.resume.smoke-resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()

        let alert = app.alerts["远程 Session 已不存在"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(resume.exists, "失效的本地恢复记录应立即淘汰")
        let create = alert.buttons["创建新 Session"]
        XCTAssertTrue(create.exists)
        create.tap()

        let creationLoading = app.descendants(matching: .any)["terminal.creation.loading"]
        XCTAssertTrue(creationLoading.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["新建终端"].exists)
        XCTAssertTrue(app.staticTexts["正在创建终端…"].exists)
        XCTAssertTrue(app.buttons["关闭"].exists)

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 5))
        sessionActions.tap()
        let current = app.descendants(matching: .any)["terminal.session-actions.current"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.label.contains("saved-session"))
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.error"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
