//
//  ConnUITests.swift
//  ConnUITests
//
//  Created by crazyball on 2026/7/19.
//

import XCTest

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
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
