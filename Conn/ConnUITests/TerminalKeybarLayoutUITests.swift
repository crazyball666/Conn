import XCTest

final class TerminalKeybarLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTerminalUsesImmersiveLayoutAndPresentsSessionActionsFromKeybar() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 5))
        XCTAssertTrue(sessionActions.isHittable)
        XCTAssertGreaterThanOrEqual(sessionActions.frame.width, 44)
        XCTAssertGreaterThanOrEqual(sessionActions.frame.height, 44)
        XCTAssertFalse(app.navigationBars.firstMatch.exists)

        sessionActions.tap()

        let actionsSheet = app.descendants(matching: .any)["terminal.session-actions"].firstMatch
        XCTAssertTrue(actionsSheet.waitForExistence(timeout: 5))
        let navigationBar = app.navigationBars["会话操作"]
        let title = navigationBar.staticTexts["会话操作"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
        XCTAssertTrue(title.exists)
        XCTAssertEqual(title.frame.midX, actionsSheet.frame.midX, accuracy: 3)
        XCTAssertTrue(app.staticTexts["deploy@127.0.0.1:2202"].exists)
        XCTAssertFalse(app.staticTexts["ops-node-01"].exists)
        XCTAssertFalse(app.staticTexts["当前终端"].exists)
        XCTAssertFalse(app.buttons["terminal.session-actions.return"].exists)
        let switchTerminal = app.buttons["terminal.session-actions.switch"]
        let closeTerminal = app.buttons["terminal.session-actions.close"]
        XCTAssertTrue(switchTerminal.isHittable)
        XCTAssertTrue(closeTerminal.isHittable)
        XCTAssertEqual(switchTerminal.frame.height, closeTerminal.frame.height, accuracy: 1)
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Terminal immersive session actions"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["terminal.session-actions.close"].tap()
        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testSessionActionsSwitchPresentsTerminalListAfterSheetDismissal() {
        let app = launchSmokeTerminal()
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 10))
        sessionActions.tap()

        let switchTerminal = app.buttons["terminal.session-actions.switch"]
        XCTAssertTrue(switchTerminal.waitForExistence(timeout: 5))
        switchTerminal.tap()

        XCTAssertTrue(app.navigationBars["终端会话"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testSessionActionsCloseDismissesTerminalPageAfterSheetDismissal() {
        let app = launchSmokeTerminal()
        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 5))
        sessionActions.tap()

        let closeTerminal = app.buttons["terminal.session-actions.close"]
        XCTAssertTrue(closeTerminal.waitForExistence(timeout: 5))
        closeTerminal.tap()

        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testSessionActionsRemainAvailableWhenShortcutBarIsDisabled() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += [
            "-conn.settings.terminalCursorBlinking", "NO",
            "-conn.settings.terminalKeybarEnabled", "NO"
        ]
        app.launch()

        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 10))
        XCTAssertTrue(sessionActions.isHittable)
        XCTAssertGreaterThanOrEqual(sessionActions.frame.width, 44)
        XCTAssertGreaterThanOrEqual(sessionActions.frame.height, 44)
        XCTAssertFalse(app.buttons["Esc"].exists)

        sessionActions.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.session-actions"].firstMatch
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testDirectionPadKeepsOriginalCompactSize() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        let directionPad = app.descendants(matching: .any)[
            "terminal.keybar.directionPad"
        ].firstMatch
        XCTAssertTrue(keybar.waitForExistence(timeout: 10))
        XCTAssertTrue(directionPad.waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["^C"].exists)
        XCTAssertFalse(app.buttons["^D"].exists)
        XCTAssertFalse(app.buttons["^Z"].exists)
        XCTAssertFalse(app.buttons["^L"].exists)
        XCTAssertFalse(app.buttons["^W"].exists)

        XCTAssertEqual(directionPad.frame.width, 40, accuracy: 1)
        XCTAssertEqual(directionPad.frame.height, 40, accuracy: 1)
        XCTAssertLessThanOrEqual(directionPad.frame.maxX, keybar.frame.maxX + 1)
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Terminal compact direction pad"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testExpandedTmuxPanelShowsAnotherActionRowWithoutClipping() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        let providerTab = app.buttons["terminal.keybar.tab.tmux"]
        XCTAssertTrue(keybar.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(keybar.frame.height, 212)
        // The expanded panel includes the device bottom safe area when the keyboard is hidden.
        XCTAssertLessThanOrEqual(keybar.frame.height, 260)
        XCTAssertTrue(providerTab.waitForExistence(timeout: 5))
        providerTab.tap()

        let sessionList = app.buttons[
            "terminal.keybar.tmux.tmux.session.list"
        ]
        let windowList = app.buttons[
            "terminal.keybar.tmux.tmux.window.list"
        ]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 5))
        XCTAssertTrue(windowList.waitForExistence(timeout: 5))
        XCTAssertTrue(sessionList.isHittable)
        XCTAssertTrue(windowList.isHittable)

        let secondSectionLastAction = app.buttons[
            "terminal.keybar.tmux.tmux.window.close"
        ]
        XCTAssertTrue(secondSectionLastAction.waitForExistence(timeout: 5))
        XCTAssertTrue(secondSectionLastAction.isHittable)
        XCTAssertGreaterThanOrEqual(secondSectionLastAction.frame.minX, keybar.frame.minX - 1)
        XCTAssertLessThanOrEqual(secondSectionLastAction.frame.maxX, keybar.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(secondSectionLastAction.frame.minY, keybar.frame.minY - 1)
        XCTAssertLessThanOrEqual(secondSectionLastAction.frame.maxY, keybar.frame.maxY + 1)
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Expanded tmux keybar layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testExpandedZellijPanelUsesProviderOwnedNativeActions() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_ZELLIJ_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let providerTab = app.buttons["terminal.keybar.tab.zellij"]
        XCTAssertTrue(providerTab.waitForExistence(timeout: 10))
        providerTab.tap()

        XCTAssertFalse(app.buttons["terminal.keybar.zellij.zellij.session.manager"].exists)
        XCTAssertTrue(app.buttons["terminal.keybar.zellij.zellij.tab.new"].exists)
        XCTAssertTrue(app.buttons["terminal.keybar.zellij.zellij.pane.split-right"].exists)
        let nextLayout = app.buttons["terminal.keybar.zellij.zellij.layout.next"]
        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        let providerScroll = keybar.scrollViews.element(boundBy: 1)
        XCTAssertTrue(providerScroll.waitForExistence(timeout: 5))
        for _ in 0 ..< 4 where !nextLayout.exists || !nextLayout.isHittable {
            providerScroll.swipeUp()
        }
        XCTAssertTrue(nextLayout.waitForExistence(timeout: 5))
        XCTAssertTrue(nextLayout.isHittable)
        XCTAssertFalse(app.buttons["terminal.keybar.zellij.tmux.window.next"].exists)

        let closePane = app.buttons["terminal.keybar.zellij.zellij.pane.close"]
        for _ in 0 ..< 4 where !closePane.exists || !closePane.isHittable {
            providerScroll.swipeDown()
        }
        XCTAssertTrue(closePane.waitForExistence(timeout: 5))
        XCTAssertTrue(closePane.isHittable)
        closePane.tap()
        let alert = app.alerts["关闭当前 Pane？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["关闭 Pane"].exists)
        alert.buttons["取消"].tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testExpandedKeybarUsesProviderToolUploadOrder() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TMUX_ACTIONS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let common = app.buttons["terminal.keybar.tab.common"]
        let tmux = app.buttons["terminal.keybar.tab.tmux"]
        let claudeCode = app.buttons["terminal.keybar.tab.claude-code"]
        let upload = app.buttons["terminal.keybar.tab.upload"]

        XCTAssertTrue(common.waitForExistence(timeout: 10))
        XCTAssertTrue(tmux.waitForExistence(timeout: 5))
        XCTAssertTrue(claudeCode.waitForExistence(timeout: 5))
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        XCTAssertLessThan(common.frame.minX, tmux.frame.minX)
        XCTAssertLessThan(tmux.frame.minX, claudeCode.frame.minX)
        XCTAssertLessThan(claudeCode.frame.minX, upload.frame.minX)
        XCTAssertEqual(claudeCode.label, "Claude Code")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testCommonPanelUsesIconKeysForClearInputAndReturn() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        XCTAssertTrue(keybar.waitForExistence(timeout: 10))

        let clearInput = app.buttons["清除"]
        let returnKey = app.buttons["回车"]
        XCTAssertTrue(clearInput.waitForExistence(timeout: 5))
        XCTAssertTrue(returnKey.exists)
        XCTAssertFalse(app.buttons["Clear"].exists)
        XCTAssertLessThan(clearInput.frame.minY, app.buttons["Esc"].frame.minY)
        XCTAssertLessThan(returnKey.frame.minY, app.buttons["Esc"].frame.minY)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testClaudeCodePanelInsertsCommandWithoutSubmitting() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_ATTACHMENTS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let claudeTab = app.buttons["terminal.keybar.tab.claude-code"]
        XCTAssertTrue(claudeTab.waitForExistence(timeout: 10))
        XCTAssertTrue(claudeTab.isHittable)
        claudeTab.tap()

        let clear = app.buttons["terminal.keybar.tool.claude-code.clear"]
        let compact = app.buttons["terminal.keybar.tool.claude-code.compact"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertTrue(compact.exists)
        XCTAssertTrue(compact.isHittable)
        compact.tap()

        let insertedText = app.staticTexts["terminal.smoke.lastInsertedText"]
        XCTAssertTrue(insertedText.waitForExistence(timeout: 5))
        XCTAssertEqual(insertedText.label, "/compact")
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Claude Code terminal shortcuts"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testUploadPanelUploadsSmokeImageAndInsertsRemotePath() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_ATTACHMENTS"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let uploadTab = app.buttons["terminal.keybar.tab.upload"]
        XCTAssertTrue(uploadTab.waitForExistence(timeout: 10))
        uploadTab.tap()

        let images = app.buttons["terminal.keybar.upload.photos"]
        let files = app.buttons["terminal.keybar.upload.files"]
        let clipboard = app.buttons["terminal.keybar.upload.clipboard"]
        XCTAssertTrue(images.waitForExistence(timeout: 5))
        XCTAssertTrue(files.exists)
        XCTAssertTrue(clipboard.exists)
        clipboard.tap()

        let successToast = app.descendants(matching: .any)["conn.toast.success"].firstMatch
        XCTAssertTrue(successToast.waitForExistence(timeout: 10))
        XCTAssertEqual(successToast.label, "已上传 1 个附件")
        let toastAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        toastAttachment.name = "Terminal attachment success toast"
        toastAttachment.lifetime = .keepAlways
        add(toastAttachment)
        let insertedText = app.staticTexts["terminal.smoke.lastInsertedText"]
        XCTAssertTrue(insertedText.waitForExistence(timeout: 5))
        XCTAssertTrue(insertedText.label.localizedCaseInsensitiveContains("ConnUploadSmoke"))
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Terminal attachment upload"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testUploadFailureUsesGlobalToastAndLeavesRetryInPanel() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_EXPANDED"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL_ATTACHMENTS_FAILURE"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let uploadTab = app.buttons["terminal.keybar.tab.upload"]
        XCTAssertTrue(uploadTab.waitForExistence(timeout: 10))
        uploadTab.tap()

        let clipboard = app.buttons["terminal.keybar.upload.clipboard"]
        XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
        clipboard.tap()

        let errorToast = app.descendants(matching: .any)["conn.toast.error"].firstMatch
        XCTAssertTrue(errorToast.waitForExistence(timeout: 5))
        XCTAssertEqual(errorToast.label, "无法建立附件上传通道。")
        XCTAssertTrue(app.buttons["terminal.keybar.upload.retry"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func launchSmokeTerminal() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()
        return app
    }
}
