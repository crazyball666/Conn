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

        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.exists)
        navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(keybarButton.waitForNonExistence(timeout: 5))

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(keybarButton.waitForExistence(timeout: 5))

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

    /// 使用模拟器里用户已经配置好的真实主机做 opt-in 验收。默认跳过，避免 CI 依赖
    /// 私有凭据；手工验收时设置 CONN_LIVE_TMUX_UI_ACCEPTANCE=1。
    @MainActor
    func testLiveTmuxWindowNavigationShowsSuccessAndDoesNotMisreportFailure() throws {
        guard ProcessInfo.processInfo.environment["CONN_LIVE_TMUX_UI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("需要模拟器内已有 38.147.173.228 凭据与 tmux Session")
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

        let tmuxChoice = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "tmux")
        ).firstMatch
        XCTAssertTrue(tmuxChoice.waitForExistence(timeout: 5))
        tmuxChoice.tap()

        let existingSession = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "$")
        ).firstMatch
        XCTAssertTrue(existingSession.waitForExistence(timeout: 20))
        existingSession.tap()

        let terminal = app.descendants(matching: .any)["terminal.viewport"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))

        // provider Tab 的出现意味着 Control Mode 已就绪且快捷动作已经发布。
        let expand = app.buttons["terminal.keybar.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        let providerTab = app.buttons["terminal.keybar.tab.tmux"]
        XCTAssertTrue(providerTab.waitForExistence(timeout: 15))
        app.buttons["terminal.keybar.collapse"].tap()

        for _ in 0 ..< 4 {
            terminal.swipeLeft(velocity: .fast)
        }

        let successToast = app.descendants(matching: .any)["conn.toast.success"].firstMatch
        XCTAssertTrue(successToast.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["conn.toast.error"].exists)
        XCTAssertFalse(app.staticTexts["持久终端操作失败，请重试"].exists)
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
        let marker = "PasteMarkerEightFourTwo"
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
        pasteButton.tap()
        Thread.sleep(forTimeInterval: 1)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Terminal paste result"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(try recognizedText(in: screenshot).contains(marker))
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
