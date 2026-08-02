//
//  ConnUITests.swift
//  ConnUITests
//
//  Created by crazyball on 2026/7/19.
//

import XCTest
import UIKit
import Vision

final class ConnUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testTerminalKeyboardViewportRestoresAfterDismissAndReopen() throws {
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
    func testTerminalContentTapKeepsKeyboardViewportVisible() throws {
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
    func testTerminalKeybarExpandsAboveKeyboardAndRestoresViewport() throws {
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
        XCTAssertTrue(app.buttons["terminal.keybar.reconnect"].exists)
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
    func testTerminalCommandPickerKeepsSearchAboveEmptyState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_TERMINAL"] = "1"
        app.launchArguments += ["-conn.settings.terminalCursorBlinking", "NO"]
        app.launch()

        let commandButton = app.buttons["terminal.keybar.commands"]
        XCTAssertTrue(commandButton.waitForExistence(timeout: 10))
        commandButton.tap()

        let searchField = app.searchFields["搜索命令"]
        let emptyTitle = app.staticTexts["还没有命令"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyTitle.waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Terminal command picker empty state"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThan(searchField.frame.midY, emptyTitle.frame.minY)
    }

    @MainActor
    func testSnippetGroupCreateAlertIsPresentedOnGroupDestination() throws {
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
    func testHostFormGroupPickerStartsCollapsed() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_HOSTFORM"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["添加主机"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["分组"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["生产"].exists)
    }

    @MainActor
    func testSnippetFormGroupPickerStartsCollapsed() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_SNIPPETS"] = "1"
        app.launch()

        let addButton = app.buttons["新增"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        let newCommand = app.buttons["新增命令"].firstMatch
        XCTAssertTrue(newCommand.waitForExistence(timeout: 5))
        newCommand.tap()

        XCTAssertTrue(app.navigationBars["新增命令"].waitForExistence(timeout: 5))
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

        let pasteButton = app.buttons["terminal.keybar.paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 10))
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
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
