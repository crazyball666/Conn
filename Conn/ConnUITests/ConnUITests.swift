//
//  ConnUITests.swift
//  ConnUITests
//
//  Created by crazyball on 2026/7/19.
//

import UIKit
import Vision
import XCTest

final class ConnUITests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run.
        // The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testRefreshIntervalUsesCompactTechnicalUnits() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_ME"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["主页刷新间隔"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["30s"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["每 30 秒"].exists)
        XCTAssertTrue(app.staticTexts["容器刷新间隔"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["每 30 秒"].exists)
    }

    @MainActor
    func testSettingsFeedbackEntryProvidesMailFallbackOnSimulator() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_ME"] = "1"
        app.launch()

        let feedback = app.buttons["settings.feedback"]
        for _ in 0..<4 where !feedback.exists {
            app.swipeUp()
        }
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        feedback.tap()

        let alert = app.alerts["无法发送邮件"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts[
            "此设备尚未配置邮件账户，反馈模板已复制到剪贴板。请粘贴到邮件中发送。"
        ].exists)
        XCTAssertTrue(alert.buttons["确定"].exists)
        alert.buttons["确定"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testEditorAndTerminalUseTenPointFontSettingInKorean() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_ME"] = "1"
        app.launchArguments += [
            "-conn.language", "ko",
            "-conn.settings.codeFontSize", "10",
            "-conn.settings.terminalFontSize", "10",
        ]
        app.launch()

        let editorLink = app.staticTexts["편집기 설정"]
        XCTAssertTrue(editorLink.waitForExistence(timeout: 10))
        editorLink.tap()
        XCTAssertTrue(app.navigationBars["편집기 설정"].waitForExistence(timeout: 5))
        let editorSize = app.steppers["settings.editor.font-size"]
        XCTAssertTrue(editorSize.waitForExistence(timeout: 5))
        XCTAssertTrue(editorSize.label.contains("글꼴 크기"))
        XCTAssertTrue(editorSize.label.contains("10 pt"))
        XCTAssertFalse(app.staticTexts["大小"].exists)

        let editorAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editorAttachment.name = "Korean editor 10pt font setting"
        editorAttachment.lifetime = .keepAlways
        add(editorAttachment)

        app.navigationBars["편집기 설정"].buttons.firstMatch.tap()
        let terminalLink = app.staticTexts["터미널 설정"]
        XCTAssertTrue(terminalLink.waitForExistence(timeout: 5))
        terminalLink.tap()
        XCTAssertTrue(app.navigationBars["터미널 설정"].waitForExistence(timeout: 5))
        let terminalSize = app.steppers["settings.terminal.font-size"]
        XCTAssertTrue(terminalSize.waitForExistence(timeout: 5))
        XCTAssertTrue(terminalSize.label.contains("글꼴 크기"))
        XCTAssertTrue(terminalSize.label.contains("10 pt"))
        XCTAssertFalse(app.staticTexts["大小"].exists)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Korean terminal 10pt font setting"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testDatabaseFailureIsCenteredAndRetryShowsProgress() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_SMOKE_DATABASE_FAILURE"] = "smoke database failure"
        app.launchEnvironment["CONN_SMOKE_DATABASE_RECOVER_ON_RETRY"] = "1"
        app.launch()

        let content = app.descendants(matching: .any)["database.failure.content"].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertEqual(content.frame.midY, window.frame.midY, accuracy: 60)

        let retry = app.buttons["database.failure.retry"]
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(content.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["主机"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)

        app.terminate()
        let loadingApp = XCUIApplication()
        loadingApp.launchEnvironment["CONN_SMOKE_DATABASE_LOADING"] = "1"
        loadingApp.launch()
        let loading = loadingApp.descendants(matching: .any)["database.initialization.loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 10))
        XCTAssertEqual(loading.frame.midY, loadingApp.windows.firstMatch.frame.midY, accuracy: 60)
        XCTAssertEqual(loadingApp.state, .runningForeground)
    }

    @MainActor
    func testTerminalKeyboardViewportRestoresAfterDismissAndReopen() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let keybarButton = app.buttons["Esc"]
        XCTAssertTrue(keybarButton.waitForExistence(timeout: 10))

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let initialKeyboardViewport = terminal.frame

        let dismissKeyboard = app.buttons["terminal.keybar.dismissKeyboard"]
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 5))
        dismissKeyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(keybarButton.exists, "收起键盘后快捷键栏与页面级会话入口应继续保留")

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(keybarButton.exists)

        let reopenedKeyboardViewport = terminal.frame
        XCTAssertEqual(reopenedKeyboardViewport.minY, initialKeyboardViewport.minY, accuracy: 1)
        XCTAssertEqual(reopenedKeyboardViewport.height, initialKeyboardViewport.height, accuracy: 1)
    }

    @MainActor
    func testTerminalContentTapKeepsKeyboardViewportVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let keybarButton = app.buttons["Esc"]
        XCTAssertTrue(keybarButton.waitForExistence(timeout: 10))

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let viewportBeforeTap = terminal.frame

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(keybarButton.exists)
        XCTAssertEqual(terminal.frame.minY, viewportBeforeTap.minY, accuracy: 1)
        XCTAssertEqual(terminal.frame.height, viewportBeforeTap.height, accuracy: 1)
    }

    @MainActor
    func testTerminalDismissKeyboardKeepsKeybarVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        let dismissKeyboard = app.buttons["terminal.keybar.dismissKeyboard"]
        XCTAssertTrue(keybar.waitForExistence(timeout: 10))
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        dismissKeyboard.tap()

        XCTAssertTrue(keybar.waitForExistence(timeout: 5))
        XCTAssertTrue(dismissKeyboard.exists)
        XCTAssertTrue(app.buttons["Esc"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        dismissKeyboard.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    /// 使用测试设备里用户已经配置好的真实 Mac 主机做 opt-in 验收。默认跳过，避免
    /// CI 依赖私有凭据；手工验收时设置 CONN_LIVE_ZELLIJ_UI_ACCEPTANCE=1。
    @MainActor
    func testLiveMacZellijInstalledByHomebrewIsAvailable() throws {
        guard ProcessInfo.processInfo.environment["CONN_LIVE_ZELLIJ_UI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("需要测试设备内已有 192.168.31.195 凭据与 Homebrew Zellij")
        }

        let app = XCUIApplication()
        app.launch()

        let terminalTab = app.tabBars.buttons["终端"]
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 10))
        terminalTab.tap()
        let newTerminal = app.buttons["新建终端"].firstMatch
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 5))
        newTerminal.tap()

        let host = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "192.168.31.195")
        ).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()

        let zellijChoice = app.buttons["new-terminal.provider.zellij"]
        XCTAssertTrue(zellijChoice.waitForExistence(timeout: 20))
        XCTAssertTrue(zellijChoice.isEnabled)
        zellijChoice.tap()

        XCTAssertTrue(
            app.textFields["Session 名称（可选）"].waitForExistence(timeout: 20),
            "Homebrew 安装的 Zellij 应被 SSH 非交互命令探测到"
        )
        XCTAssertFalse(app.staticTexts["不可用"].exists)
    }

    @MainActor
    func testLiveTmuxWindowNavigationShowsSuccessAndDoesNotMisreportFailure() throws {
        guard ProcessInfo.processInfo.environment["CONN_LIVE_TMUX_UI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("需要测试设备内已有 38.147.173.228 凭据与 tmux")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let terminalTab = app.tabBars.buttons["终端"]
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 10))
        terminalTab.tap()

        let newTerminal = app.buttons["新建终端"].firstMatch
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 5))
        newTerminal.tap()

        let host = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "38.147.173.228")
        ).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()

        let tmuxChoice = app.buttons["new-terminal.provider.tmux"]
        XCTAssertTrue(tmuxChoice.waitForExistence(timeout: 20))
        XCTAssertTrue(tmuxChoice.isEnabled)
        tmuxChoice.tap()

        // Keep live acceptance isolated from the user's existing tmux topology. Cleanup
        // always targets this exact temporary Session, including every queued Window/Pane.
        let sessionSuffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(12)
        let sessionName = "conn-ui-\(sessionSuffix)"
        let sessionField = app.textFields["Session 名称（可选）"]
        XCTAssertTrue(sessionField.waitForExistence(timeout: 20))
        sessionField.tap()
        sessionField.typeText(String(sessionName))
        let createSession = app.buttons["创建并连接"]
        XCTAssertTrue(createSession.isEnabled)
        createSession.tap()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        addTeardownBlock {
            guard terminal.exists else { return }
            terminal.tap()
            terminal.typeText("tmux kill-session -t \(sessionName)\n")
        }

        // Generate enough real tmux history to verify that a vertical swipe is consumed
        // by copy mode rather than SwiftTerm's local UIScrollView.
        terminal.tap()
        terminal.typeText("seq 1 120\n")
        terminal.swipeDown(velocity: .fast)
        XCTAssertFalse(
            app.descendants(matching: .any)["terminal.review.text"].firstMatch
                .waitForExistence(timeout: 1)
        )
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.warning"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.error"].firstMatch.exists)

        // tmux copy mode is entered with scroll-exit enabled. Repeated downward history
        // navigation must return to the live bottom and release subsequent typing to the
        // shell instead of leaving the client stuck at the [0/…] position indicator.
        for _ in 0 ..< 8 {
            terminal.swipeUp(velocity: .fast)
        }
        let scrollExitMarker = "CONN_SCROLL_EXIT_OK"
        terminal.tap()
        terminal.typeText("printf '\(scrollExitMarker)\\n'\n")
        var recognizedAfterScroll = ""
        for _ in 0 ..< 10 {
            recognizedAfterScroll = try recognizedText(in: XCUIScreen.main.screenshot())
            if recognizedAfterScroll.contains(scrollExitMarker) { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(
            recognizedAfterScroll.contains(scrollExitMarker),
            "滚动到实时底部后必须自动退出 tmux copy mode 并恢复 Shell 输入"
        )
        XCTAssertFalse(app.staticTexts["终端连接已断开"].exists)

        // provider Tab 的出现意味着 Control Mode 已就绪且快捷动作已经发布。
        let expand = app.buttons["terminal.keybar.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        let escape = app.buttons["Esc"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5))
        escape.tap()
        let providerTab = app.buttons["terminal.keybar.tab.tmux"]
        XCTAssertTrue(providerTab.waitForExistence(timeout: 15))
        providerTab.tap()

        // Queue a real burst while the first Control Mode command is still in flight. Every
        // tap must be retained and topology synchronization must complete before the next
        // intent resolves its current target.
        let newWindow = app.buttons["terminal.keybar.tmux.tmux.window.new"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(newWindow.isHittable)
        for _ in 0 ..< 4 { newWindow.tap() }
        app.buttons["terminal.keybar.collapse"].tap()

        for _ in 0 ..< 4 {
            terminal.swipeLeft(velocity: .fast)
        }

        let successToast = app.descendants(matching: .any)["conn.toast.success"].firstMatch
        XCTAssertTrue(successToast.waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.descendants(matching: .any)["conn.toast.error"].firstMatch
                .waitForExistence(timeout: 5),
            "快速切换队列执行完成前后均不得出现失败 Toast"
        )
        XCTAssertFalse(app.staticTexts["持久终端操作失败，请重试"].exists)

        // Remove the temporary Window and leave the user's Session unchanged.
        expand.tap()
        XCTAssertTrue(providerTab.waitForExistence(timeout: 5))
        providerTab.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.exists {
            app.buttons["terminal.keybar.dismissKeyboard"].tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let closeWindow = app.buttons["terminal.keybar.tmux.tmux.window.close"]
        XCTAssertTrue(closeWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.exists)
        closeWindow.tap()
        let closeAlert = app.alerts["关闭当前 Window？"]
        XCTAssertTrue(closeAlert.waitForExistence(timeout: 5))
        closeAlert.buttons["关闭 Window"].tap()
        XCTAssertTrue(closeAlert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["conn.toast.error"].firstMatch
                .waitForExistence(timeout: 8),
            "键盘布局更新与关闭 Window 串行执行，不得出现失败 Toast"
        )

        // Reproduce the reported path on the real attachment: keep the terminal keyboard
        // active, create a temporary Pane, then confirm its deletion through a system Alert.
        if !keyboard.exists {
            app.buttons["terminal.keybar.dismissKeyboard"].tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(providerTab.waitForExistence(timeout: 5))
        providerTab.tap()
        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        let providerScroll = keybar.scrollViews.element(boundBy: 1)
        XCTAssertTrue(providerScroll.waitForExistence(timeout: 5))
        let splitPane = app.buttons["terminal.keybar.tmux.tmux.pane.split-horizontal"]
        XCTAssertTrue(splitPane.waitForExistence(timeout: 5))
        for _ in 0 ..< 4 where !splitPane.isHittable {
            keybar.swipeUp()
        }
        XCTAssertTrue(splitPane.isHittable)
        for _ in 0 ..< 4 { splitPane.tap() }

        let closePane = app.buttons["terminal.keybar.tmux.tmux.pane.close"]
        for _ in 0 ..< 4 where !closePane.exists || !closePane.isHittable {
            providerScroll.swipeUp()
        }
        XCTAssertTrue(closePane.waitForExistence(timeout: 5))
        XCTAssertTrue(closePane.isHittable)
        XCTAssertTrue(keyboard.exists)
        closePane.tap()
        let closePaneAlert = app.alerts["关闭当前 Pane？"]
        XCTAssertTrue(closePaneAlert.waitForExistence(timeout: 5))
        closePaneAlert.buttons["关闭 Pane"].tap()
        XCTAssertTrue(closePaneAlert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["conn.toast.error"].firstMatch
                .waitForExistence(timeout: 8),
            "关闭 Pane 异步执行完成前不得出现失败 Toast"
        )
        XCTAssertFalse(app.staticTexts["持久终端操作失败，请重试"].exists)

        // Closing the page must hide this exact tmux client without ending the Session.
        // Reopening it must redraw from tmux instead of replaying stale local ANSI.
        let sessionActions = app.buttons["terminal.keybar.session-actions"]
        XCTAssertTrue(sessionActions.waitForExistence(timeout: 5))
        sessionActions.tap()
        let closePage = app.buttons["terminal.session-actions.close"]
        XCTAssertTrue(closePage.waitForExistence(timeout: 5))
        closePage.tap()
        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5))

        let hostCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.host.")
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 10))
        let sessionRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", String(sessionName))
        ).firstMatch
        if !sessionRow.exists {
            hostCard.tap()
        }
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 10))
        sessionRow.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.error"].firstMatch.exists)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(
            app.descendants(matching: .any)["conn.toast.error"].firstMatch
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testTerminalKeybarExpandsAboveKeyboardAndRestoresViewport() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        let keybar = app.descendants(matching: .any)["terminal.keybar"].firstMatch
        let expand = app.buttons["terminal.keybar.expand"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(keybar.waitForExistence(timeout: 10))
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["terminal.keybar.dismissKeyboard"].exists)
        XCTAssertTrue(app.buttons["terminal.keybar.commands"].exists)
        let compactViewport = terminal.frame
        XCTAssertLessThanOrEqual(terminal.frame.maxY, keybar.frame.minY + 1)

        expand.tap()

        XCTAssertTrue(app.buttons["terminal.keybar.collapse"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["terminal.keybar.paste"].exists)
        XCTAssertTrue(app.buttons["terminal.keybar.commands"].exists)
        XCTAssertTrue(app.buttons["terminal.keybar.reconnect"].exists)
        XCTAssertTrue(app.buttons["terminal.keybar.dismissKeyboard"].exists)
        XCTAssertTrue(app.buttons["⇧Tab"].exists)
        let shrunk = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in terminal.frame.height < compactViewport.height },
            object: terminal
        )
        XCTAssertEqual(XCTWaiter.wait(for: [shrunk], timeout: 5), .completed)
        XCTAssertLessThan(terminal.frame.height, compactViewport.height)
        XCTAssertLessThanOrEqual(terminal.frame.maxY, keybar.frame.minY + 1)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Terminal expanded keybar"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["terminal.keybar.collapse"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(terminal.frame.height - compactViewport.height) <= 1 },
            object: terminal
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertEqual(terminal.frame.height, compactViewport.height, accuracy: 1)
        XCTAssertLessThanOrEqual(terminal.frame.maxY, keybar.frame.minY + 1)
    }

    @MainActor
    func testTerminalCommandPickerShowsScriptSearchAndResults() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let commandButton = app.buttons["terminal.keybar.commands"]
        XCTAssertTrue(commandButton.waitForExistence(timeout: 10))
        commandButton.tap()

        let searchField = app.searchFields["搜索脚本"]
        let scriptTitle = app.staticTexts["系统概览"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(scriptTitle.waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Terminal script picker"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThan(searchField.frame.midY, scriptTitle.frame.minY)
    }

    @MainActor
    func testSnippetGroupCreateAlertIsPresentedOnGroupDestination() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_SNIPPETS"] = "1"
        app.launch()

        let more = app.buttons["更多操作"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let manageGroups = app.buttons["管理分组"]
        XCTAssertTrue(manageGroups.waitForExistence(timeout: 5))
        manageGroups.tap()
        XCTAssertTrue(app.navigationBars["分组"].waitForExistence(timeout: 5))

        let addButton = app.navigationBars["分组"].buttons["新增分组"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        XCTAssertTrue(app.alerts["新增分组"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["分组"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Snippet group create alert on destination"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHostFormGroupPickerStartsCollapsed() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_HOSTFORM"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["添加主机"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["分组"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["生产"].exists)
        XCTAssertFalse(app.staticTexts["备注"].exists)
    }

    @MainActor
    func testAddingHostFromServersSavesWithoutCrashing() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        app.buttons["新增"].tap()
        let addServer = app.buttons["新增主机"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 5))
        addServer.tap()

        XCTAssertTrue(app.navigationBars["添加主机"].waitForExistence(timeout: 5))
        let address = app.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "example.com 或 10.0.0.1")
        ).firstMatch
        let username = app.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "root")
        ).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("203.0.113.10")
        username.tap()
        username.typeText("root")

        let save = app.navigationBars["添加主机"].buttons["保存"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "203.0.113.10")
        ).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAddingHostWithExistingTerminalDoesNotCrash() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_ACTIVE_TERMINAL"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        app.buttons["新增"].tap()
        XCTAssertTrue(app.buttons["新增主机"].waitForExistence(timeout: 5))
        app.buttons["新增主机"].tap()

        XCTAssertTrue(app.navigationBars["添加主机"].waitForExistence(timeout: 5))
        let marker = "active-terminal-save"
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
        name.tap()
        name.typeText(marker)
        address.tap()
        address.typeText("203.0.113.20")
        username.tap()
        username.typeText("root")
        app.navigationBars["添加主机"].buttons["保存"].tap()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", marker)
        ).firstMatch.waitForExistence(timeout: 5))

        app.tabBars.buttons["终端"].tap()
        let existingHost = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.host.")
        ).firstMatch
        XCTAssertTrue(existingHost.waitForExistence(timeout: 5))
        existingHost.tap()
        XCTAssertTrue(app.buttons["terminal.session.smoke-existing-terminal"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testEditingHostFromServersSavesWithoutCrashing() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        let hostCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "web-01")
        ).firstMatch
        XCTAssertTrue(hostCard.waitForExistence(timeout: 5))
        hostCard.press(forDuration: 1)
        let edit = app.buttons["编辑"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let navigationBar = app.navigationBars["编辑主机"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
        navigationBar.buttons["保存"].tap()

        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "web-01")
        ).firstMatch.waitForExistence(timeout: 5))
    }

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
        XCTAssertEqual(app.state, .runningForeground)
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
    func testSnippetFormGroupPickerStartsCollapsed() {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_SNIPPETS"] = "1"
        app.launch()

        let addButton = app.buttons["新增"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        let newScript = app.buttons["新增脚本"].firstMatch
        XCTAssertTrue(newScript.waitForExistence(timeout: 5))
        newScript.tap()

        XCTAssertTrue(app.navigationBars["新增脚本"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["分组"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["还没有分组，先到分组管理中创建。"].exists)
    }

    @MainActor
    func testTerminalPasteButtonWritesClipboardText() throws {
        let app = XCUIApplication()
        let marker = "Paste842"
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchEnvironment["CONN_SMOKE_PASTE_TEXT"] = marker
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let expand = app.buttons["terminal.keybar.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()

        let pasteButton = app.buttons["terminal.keybar.paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
        for _ in 0 ..< 6 {
            pasteButton.tap()
        }
        Thread.sleep(forTimeInterval: 1)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Terminal paste result"
        attachment.lifetime = .keepAlways
        add(attachment)

        let recognized = try recognizedText(in: screenshot)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
        XCTAssertGreaterThanOrEqual(
            recognized.components(separatedBy: marker).count - 1,
            5,
            "快速连续输入不应丢失或打乱终端写入"
        )
        XCTAssertTrue(pasteButton.isHittable)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func recognizedText(in screenshot: XCUIScreenshot) throws -> String {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    @MainActor
    func testLaunchPerformance() {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
