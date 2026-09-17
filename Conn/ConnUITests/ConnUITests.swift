import XCTest

final class ConnUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Opt in with an authorized saved host UUID in the test-runner environment.
    /// Tests the actual app graph, including Keychain and embedded node restart.
    @MainActor
    func testSavedPrivateNetworkHostConnectsAfterAppRestart() throws {
        guard let hostID = ProcessInfo.processInfo.environment["CONN_TEST_PRIVATE_NETWORK_HOST_ID"],
              !hostID.isEmpty else {
            throw XCTSkip("Requires an explicitly authorized saved private-network host")
        }
        let app = XCUIApplication()
        for attempt in 1...2 {
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 15))
            let hostCard = app.buttons["servers.host.\(hostID)"]
            XCTAssertTrue(hostCard.waitForExistence(timeout: 10))
            hostCard.press(forDuration: 1)
            let edit = app.buttons["servers.host.edit.\(hostID)"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            let form = app.descendants(matching: .any)["host-form"]
            XCTAssertTrue(form.waitForExistence(timeout: 5))
            let testConnection = app.buttons["host-form.test-connection"]
            for _ in 0..<6 where !testConnection.isHittable { form.swipeUp() }
            XCTAssertTrue(testConnection.isHittable)
            testConnection.tap()
            let success = app.descendants(matching: .any)["diagnostics.success"].firstMatch
            XCTAssertTrue(success.waitForExistence(timeout: 45), "Saved private-network connection must succeed")
            XCTAssertEqual(app.state, .runningForeground)
            print("CONN-INTEGRATION: saved private-network SSH connection succeeded, attempt \(attempt)")
            app.buttons["diagnostics.done"].tap()
            if attempt == 1 { app.terminate() }
        }
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
    func testToastUsesCompactMultilineStatusCard() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-conn.settings.appearance", "light",
            "-conn.ui-test.toast", "error"
        ]
        app.launchEnvironment["CONN_UI_TEST_TOAST_MESSAGE"] =
            "连接失败：目标设备无响应，请检查地址、防火墙和 SSH 服务状态。"
        app.launch()

        let toast = app.descendants(matching: .any)["conn.toast.error"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(toast.frame.width, 320, "Toast 不应再铺满页面")
        XCTAssertGreaterThan(toast.frame.height, 44, "长文案应自然换行并撑开卡片")
        XCTAssertEqual(app.state, .runningForeground)

        let screenshot = XCTAttachment(screenshot: toast.screenshot())
        screenshot.name = "toast-compact-multiline"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testToastUsesLightSurfaceInDarkAppearance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-conn.settings.appearance", "dark",
            "-conn.ui-test.toast", "warning"
        ]
        app.launchEnvironment["CONN_UI_TEST_TOAST_MESSAGE"] =
            "警告：当前连接质量较差，请检查网络后再继续操作。"
        app.launch()

        let toast = app.descendants(matching: .any)["conn.toast.warning"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(toast.frame.width, 320, "Toast 不应再铺满页面")
        XCTAssertGreaterThan(toast.frame.height, 44, "长文案应自然换行并撑开卡片")
        XCTAssertEqual(app.state, .runningForeground)

        let screenshot = XCTAttachment(screenshot: toast.screenshot())
        screenshot.name = "toast-theme-aware-dark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testToastUsesContentWidthForShortMessage() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-conn.settings.appearance", "light",
            "-conn.ui-test.toast", "error"
        ]
        app.launchEnvironment["CONN_UI_TEST_TOAST_MESSAGE"] = "已保存"
        app.launch()

        let toast = app.descendants(matching: .any)["conn.toast.error"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertLessThan(toast.frame.width, 180, "短文案应按内容收缩，而不是固定成大卡片")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        XCTAssertEqual(toast.frame.midX, window.frame.midX, accuracy: 1, "Toast 应水平居中")
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
    func testTerminalComposerKeepsMultilineDraftUntilExplicitSend() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "pro"
        app.launch()

        let hostCard = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "servers.host.")
        ).firstMatch
        guard hostCard.waitForExistence(timeout: 15) else {
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

        let input = app.textViews["terminal.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["terminal.composer.voice"].waitForExistence(timeout: 5))
        let emptyValue = input.value as? String ?? ""
        input.tap()
        // typeText lets XCTest switch a simulator's hardware-keyboard mode to software input.
        input.typeText("p")
        waitForComposerKeyboard(app, visible: true)
        assertComposerBelongsToBottomBar(app, aboveKeyboard: true)
        input.typeText("rintf conn_composer_keyboard")
        input.typeText("\n")
        XCTAssertEqual(input.value as? String, emptyValue, "Compact Return must submit and clear instead of adding a newline")
        input.typeText("printf one")

        let draft = input.value as? String ?? ""
        XCTAssertTrue(draft.contains("printf one"))
        XCTAssertFalse(draft.contains("\n"))

        let expandEditor = app.buttons["terminal.composer.expand"]
        XCTAssertTrue(expandEditor.waitForExistence(timeout: 5))
        expandEditor.tap()
        let editor = app.textViews["terminal.composer.expanded-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        waitForComposerKeyboard(app, visible: true)
        // The terminal intentionally stays mounted. XCTest may still resolve
        // hidden descendants, so existence is not a visibility/interaction test.
        XCTAssertFalse(app.buttons["terminal.keybar.expand"].isHittable, "Fullscreen editing must prevent interaction with the underlying terminal")
        XCTAssertEqual(editor.value as? String, draft)
        XCTAssertGreaterThan(editor.frame.height, 150)
        editor.tap()
        editor.typeText("\nprintf two\nprintf three")
        let expandedDraft = editor.value as? String
        XCTAssertEqual(expandedDraft, draft + "\nprintf two\nprintf three")
        let fullImage = XCTAttachment(screenshot: app.screenshot())
        fullImage.name = "composer-fullscreen"
        fullImage.lifetime = .keepAlways
        add(fullImage)
        app.buttons["terminal.composer.done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        // Assert before any tap/typeText that could reopen a dismissed keyboard.
        waitForComposerKeyboard(app, visible: true)
        XCTAssertEqual(input.value as? String, expandedDraft, "Done must retain the multiline draft without sending")

        let send = app.buttons["terminal.composer.send"]
        XCTAssertTrue(send.exists)
        XCTAssertTrue(send.isEnabled, "Unavailable speech must not disable typed input")
        assertComposerBelongsToBottomBar(app, aboveKeyboard: true)
        send.tap()
        let confirmSend = app.buttons["terminal.composer.confirm-send"]
        if confirmSend.waitForExistence(timeout: 2) {
            app.buttons["terminal.composer.cancel-send"].tap()
            XCTAssertEqual(input.value as? String, expandedDraft, "Cancelling unsafe paste must retain the draft")
            XCTAssertTrue(send.isEnabled, "Cancelling must unlock submission")
            send.tap()
            XCTAssertTrue(confirmSend.waitForExistence(timeout: 5))
            confirmSend.tap()
        }
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, emptyValue)
        input.typeText("draft")
        XCTAssertEqual(input.value as? String, "draft", "Send must preserve focus for continuous editing")
        input.doubleTap()
        input.typeText("draft")
        XCTAssertEqual(input.value as? String, "draft", "Shared touch feedback must not prevent native word selection")
        app.buttons["terminal.keybar.dismissKeyboard"].tap()
        waitForComposerKeyboard(app, visible: false)
        assertComposerBelongsToBottomBar(app)
        app.buttons["terminal.keybar.dismissKeyboard"].tap()
        input.typeText(" stays here")
        waitForComposerKeyboard(app, visible: true)
        XCTAssertEqual(input.value as? String, "draft stays here", "Reopening must retain the composer as input destination")
        expandEditor.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        waitForComposerKeyboard(app, visible: true)
        editor.tap()
        editor.typeText("\nline two\nline three\nline four\nline five\nline six")
        app.buttons["terminal.composer.done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        waitForComposerKeyboard(app, visible: true)
        XCTAssertEqual(input.value as? String, "draft stays here\nline two\nline three\nline four\nline five\nline six")
        assertComposerBelongsToBottomBar(app, aboveKeyboard: true)
        input.swipeDown(velocity: .slow)
        assertComposerBelongsToBottomBar(app, aboveKeyboard: true)
        input.swipeUp(velocity: .slow)
        XCTAssertEqual(input.value as? String, "draft stays here\nline two\nline three\nline four\nline five\nline six", "Scrolling must not mutate or submit the draft")
        assertComposerBelongsToBottomBar(app, aboveKeyboard: true)
        app.buttons["terminal.keybar.dismissKeyboard"].tap()
        waitForComposerKeyboard(app, visible: false)
        app.buttons["terminal.keybar.expand"].tap()
        XCTAssertTrue(app.buttons["terminal.keybar.collapse"].waitForExistence(timeout: 5))
        assertComposerBelongsToBottomBar(app)
        app.buttons["terminal.keybar.collapse"].tap()
        app.buttons["terminal.keybar.close-terminal"].tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testExpandedComposerSendMatchesVoiceButton() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "pro"
        app.launch()
        let host = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "servers.host.")).firstMatch
        guard host.waitForExistence(timeout: 15) else {
            throw XCTSkip("当前模拟器没有已保存的主机配置")
        }
        host.tap()
        let open = app.buttons["host.open-terminal"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let plain = app.buttons["new-terminal.provider.plain"]
        if plain.waitForExistence(timeout: 5) { plain.tap() }
        let input = app.textViews["terminal.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        app.buttons["terminal.composer.expand"].tap()
        let editor = app.textViews["terminal.composer.expanded-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let expanded = app.descendants(matching: .any)["terminal.composer.expanded"].firstMatch
        let send = expanded.buttons["terminal.composer.send"]
        let voice = expanded.buttons["terminal.composer.voice"]
        XCTAssertTrue(send.exists)
        XCTAssertTrue(voice.exists)
        XCTAssertEqual(send.frame.width, voice.frame.width, accuracy: 0.5)
        XCTAssertEqual(send.frame.height, voice.frame.height, accuracy: 0.5)
        XCTAssertEqual(send.frame.midY, voice.frame.midY, accuracy: 0.5)
        XCTAssertFalse(send.isEnabled, "An empty draft must not become sendable when resized")
        editor.tap()
        editor.typeText("draft only")
        XCTAssertTrue(send.isEnabled)
        XCTAssertEqual(send.frame.size, voice.frame.size)
        let screenshot = XCTAttachment(screenshot: expanded.screenshot())
        screenshot.name = "expanded-composer-matching-actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["terminal.composer.done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "draft only")
        XCTAssertEqual(app.buttons["terminal.composer.send"].frame.height, 26, accuracy: 1,
                       "Compact send must retain its smaller in-field size")
        XCTAssertEqual(app.state, .runningForeground)
        app.buttons["terminal.keybar.close-terminal"].tap()
    }

    @MainActor
    func testTerminalComposerVoiceButtonsKeepKeyboard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "pro"
        app.launch()
        let host = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "servers.host.")).firstMatch
        guard host.waitForExistence(timeout: 15) else {
            throw XCTSkip("当前模拟器没有已保存的主机配置")
        }
        host.tap()
        let open = app.buttons["host.open-terminal"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let plain = app.buttons["new-terminal.provider.plain"]
        if plain.waitForExistence(timeout: 5) { plain.tap() }
        let input = app.textViews["terminal.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        let voice = app.buttons["terminal.composer.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        guard voice.isEnabled else {
            throw XCTSkip("当前模拟器未提供离线语音识别，无法验收真实录音按钮")
        }
        input.tap()
        input.typeText("voice focus check")
        waitForComposerKeyboard(app, visible: true)
        let idleLabel = voice.label
        voice.tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 1) {
            throw XCTSkip("系统正在请求语音权限；需用户授权后验收录音，不将权限弹窗计作焦点回归")
        }
        let recording = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            voice.exists && voice.label != idleLabel && voice.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 5), .completed)
        waitForComposerKeyboard(app, visible: true)
        voice.tap()
        waitForComposerKeyboard(app, visible: true)
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            voice.exists && voice.label == idleLabel && voice.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
        XCTAssertEqual(app.state, .runningForeground)
        app.buttons["terminal.keybar.close-terminal"].tap()
    }

    @MainActor
    private func waitForComposerKeyboard(
        _ app: XCUIApplication, visible: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        // UIKit can retain an offscreen keyboard preview after dismissal; existence is not visibility.
        let settled = NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            let isVisible = keyboard.exists && keyboard.frame.minY < app.frame.maxY - 100
            return isVisible == visible
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 8),
            .completed, file: file, line: line
        )
    }

    @MainActor
    private func assertComposerBelongsToBottomBar(
        _ app: XCUIApplication,
        aboveKeyboard: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bar = app.descendants(matching: .any)["terminal.input-bar"].firstMatch
        let composer = app.descendants(matching: .any)["terminal.composer"].firstMatch
        let field = app.descendants(matching: .any)["terminal.composer.field"].firstMatch
        let voice = app.buttons["terminal.composer.voice"]
        let send = app.buttons["terminal.composer.send"]
        let expand = app.buttons["terminal.composer.expand"]
        XCTAssertTrue(bar.exists, file: file, line: line)
        // Measure semantic controls, not decorative background bounds.
        let keyboardButton = app.buttons["terminal.keybar.dismissKeyboard"]
        let rowGap = keyboardButton.frame.minY - composer.frame.maxY
        XCTAssertGreaterThanOrEqual(rowGap, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(rowGap, 5, file: file, line: line)
        XCTAssertEqual(voice.frame.height, 36, accuracy: 1, file: file, line: line)
        XCTAssertEqual(send.frame.height, 26, accuracy: 1, file: file, line: line)
        XCTAssertEqual(expand.frame.size, send.frame.size, "Expand and send must have the same visible/hit bounds", file: file, line: line)
        XCTAssertLessThan(expand.frame.maxX, send.frame.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(expand.frame.minX, field.frame.minX, file: file, line: line)
        XCTAssertEqual(expand.frame.midY, send.frame.midY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(field.frame.height, 36, accuracy: 1, "Draft length must not grow the input row", file: file, line: line)
        XCTAssertEqual(voice.frame.height, field.frame.height, accuracy: 1, file: file, line: line)
        XCTAssertLessThanOrEqual(send.frame.maxX, field.frame.maxX + 1, file: file, line: line)
        XCTAssertGreaterThan(voice.frame.minX, field.frame.maxX, file: file, line: line)
        if aboveKeyboard {
            // iOS exposes the prediction/IME row separately from the keyboard's key grid.
            let assistant = app.otherElements["SystemInputAssistantView"].firstMatch
            let keyboardTop = assistant.exists && assistant.frame.minY < app.frame.maxY
                ? assistant.frame.minY : app.keyboards.firstMatch.frame.minY
            // iOS 26's keyboard AX frame excludes its rounded top margin (17pt
            // on this device). Its panel is flush in screenshots; the key-grid
            // boundary is not the panel boundary. Assert no overlap or extra row.
            let keyboardGap = keyboardTop - keyboardButton.frame.maxY
            XCTAssertGreaterThanOrEqual(keyboardGap, -2, file: file, line: line)
            XCTAssertLessThanOrEqual(keyboardGap, 22, file: file, line: line)
        } else {
            if app.buttons["terminal.keybar.expand"].exists {
                let bottomInset = app.frame.maxY - keyboardButton.frame.maxY
                XCTAssertGreaterThanOrEqual(bottomInset, 0, file: file, line: line)
                XCTAssertLessThanOrEqual(bottomInset, 36, "Only the Home Indicator inset may remain below the bar", file: file, line: line)
            }
        }
        // Capture only the accessory, excluding private host names and terminal output.
        // Decorative touch ripples inflate AX container bounds even when hidden from accessibility.
        let screenshot = app.screenshot().image
        guard let fullImage = screenshot.cgImage else {
            XCTFail("Could not capture the accessory", file: file, line: line)
            return
        }
        let scale = CGFloat(fullImage.width) / app.frame.width
        let crop = CGRect(x: 0, y: composer.frame.minY - 8, width: app.frame.width,
                          height: app.frame.maxY - composer.frame.minY + 8)
        let pixels = CGRect(x: 0, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
        guard let image = fullImage.cropping(to: pixels) else {
            XCTFail("Could not capture the accessory", file: file, line: line)
            return
        }
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = aboveKeyboard ? "composer-keyboard-visible" : "composer-keyboard-hidden"
        attachment.lifetime = .keepAlways
        add(attachment)
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
        XCTAssertTrue(app.descendants(matching: .any)["paywall.feature.hosts"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.feature.files"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.feature.docker"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.feature.batch"].firstMatch.exists)
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
    private func openNewHost(_ app: XCUIApplication) {
        // Form tests exercise editing, not the separately tested free-tier host limit.
        app.launchEnvironment["CONN_SUBSCRIPTION_STATE"] = "pro"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["tab.servers"].waitForExistence(timeout: 10))
        app.buttons["servers.add"].tap()
        XCTAssertTrue(app.buttons["servers.add-host"].waitForExistence(timeout: 5))
        app.buttons["servers.add-host"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["host-form"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func openNetworkSettings(_ app: XCUIApplication) {
        let route = app.descendants(matching: .any)["host-form.network-route"].firstMatch
        for _ in 0..<4 where !route.isHittable { app.descendants(matching: .any)["host-form"].firstMatch.swipeUp() }
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        guard route.isHittable else { return XCTFail("Network route is not reachable") }
        route.tap()
        XCTAssertTrue(app.descendants(matching: .any)["network-route.form"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func networkMode(_ mode: String, in app: XCUIApplication) -> XCUIElement {
        let segmented = app.segmentedControls["network-route.mode"]
        if segmented.exists {
            let index = ["direct", "privateNetwork", "proxy"].firstIndex(of: mode)!
            return segmented.buttons.element(boundBy: index)
        }
        return app.buttons["network-route.mode.\(mode)"]
    }

    @MainActor
    func testHostFormExposesPrivateNetworkProfileEditor() {
        let app = XCUIApplication()
        openNewHost(app)
        openNetworkSettings(app)
        networkMode("privateNetwork", in: app).tap()
        app.buttons["host-form.private-network.add"].tap()
        XCTAssertTrue(app.textFields["private-network-profile.name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["private-network-profile.control-url"].exists)
        app.buttons["private-network-profile.provider"].tap()
        app.buttons["Headscale"].tap()
        XCTAssertTrue(app.textFields["private-network-profile.control-url"].waitForExistence(timeout: 5))
        let controlURL = app.textFields["private-network-profile.control-url"]
        controlURL.tap()
        controlURL.typeText("https://headscale.example.com")
        app.buttons["private-network-profile.provider"].tap()
        app.buttons["Tailscale"].tap()
        XCTAssertFalse(controlURL.exists)
        app.buttons["private-network-profile.provider"].tap()
        app.buttons["Headscale"].tap()
        XCTAssertEqual(controlURL.value as? String, "https://headscale.example.com")
        XCTAssertTrue(app.secureTextFields["private-network-profile.auth-key"].exists)
        let profileScreenshot = XCTAttachment(screenshot: app.screenshot())
        profileScreenshot.name = "headscale-profile"
        profileScreenshot.lifetime = .keepAlways
        add(profileScreenshot)
        app.buttons["private-network-profile.cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["network-route.form"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(networkMode("privateNetwork", in: app).isSelected)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testHostFormExposesProxyAndJumpHostSettings() {
        let app = XCUIApplication()
        app.launchArguments += ["-conn.settings.appearance", "light"]
        openNewHost(app)
        openNetworkSettings(app)
        networkMode("proxy", in: app).tap()
        let proxyHost = app.textFields["host-form.proxy-host"]
        XCTAssertTrue(proxyHost.waitForExistence(timeout: 5))
        proxyHost.tap()
        proxyHost.typeText("proxy.example.com")
        networkMode("direct", in: app).tap()
        XCTAssertFalse(proxyHost.exists)
        networkMode("proxy", in: app).tap()
        XCTAssertEqual(proxyHost.value as? String, "proxy.example.com")
        XCTAssertTrue(app.textFields["host-form.proxy-port"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "network-proxy-light"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(proxyHost.value as? String, "proxy.example.com")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openNetworkSettings(app)
        XCTAssertEqual(proxyHost.value as? String, "proxy.example.com")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let jump = app.descendants(matching: .any)["host-form.jump-route"].firstMatch
        for _ in 0..<3 where !jump.isHittable { app.descendants(matching: .any)["host-form"].firstMatch.swipeUp() }
        XCTAssertTrue(jump.isHittable)
        let summaryScreenshot = XCTAttachment(screenshot: app.screenshot())
        summaryScreenshot.name = "host-advanced-summary"
        summaryScreenshot.lifetime = .keepAlways
        add(summaryScreenshot)
        jump.tap()
        XCTAssertTrue(app.descendants(matching: .any)["jump-route.form"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["host-form.jump-toggle"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "jump-route.remove.")).count, 0)
        let choose = app.descendants(matching: .any)["host-form.jump-add"].firstMatch
        XCTAssertTrue(choose.exists)
        choose.tap()
        XCTAssertTrue(app.descendants(matching: .any)["jump-route.picker"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["jump-route.form"].firstMatch.waitForExistence(timeout: 5))
        // Opening and cancelling the picker must not silently choose the first saved host.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "jump-route.remove.")).count, 0)
        choose.tap()
        let savedHost = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "jump-route.select.")).firstMatch
        XCTAssertTrue(savedHost.waitForExistence(timeout: 5), "Requires at least one saved host for jump selection")
        savedHost.tap()
        let remove = app.buttons["jump-route.remove.0"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.descendants(matching: .any)["host-form.jump-route"].firstMatch.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertFalse(remove.exists)
        let jumpScreenshot = XCTAttachment(screenshot: app.screenshot())
        jumpScreenshot.name = "empty-jump-selection"
        jumpScreenshot.lifetime = .keepAlways
        add(jumpScreenshot)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testAdvancedSettingsSupportsLargeTextAndDarkAppearance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-conn.settings.appearance", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        openNewHost(app)
        openNetworkSettings(app)
        let proxy = networkMode("proxy", in: app)
        XCTAssertTrue(proxy.waitForExistence(timeout: 5))
        proxy.tap()
        let proxyHost = app.textFields["host-form.proxy-host"]
        let form = app.descendants(matching: .any)["network-route.form"].firstMatch
        for _ in 0..<4 where !proxyHost.isHittable { form.swipeUp() }
        XCTAssertTrue(proxyHost.isHittable)
        proxyHost.tap()
        proxyHost.typeText("proxy.example.com")
        form.swipeUp()
        XCTAssertEqual(proxyHost.value as? String, "proxy.example.com")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "network-proxy-dark-large-text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(app.state, .runningForeground)
    }
    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
