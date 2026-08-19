import XCTest

final class LocalizationSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEverySupportedNonSourceLanguageRendersAppAndPackageCopy() throws {
        let cases = [
            (locale: "en", hosts: "Hosts", terminal: "Terminal", empty: "No Terminals"),
            (locale: "ja", hosts: "ホスト", terminal: "ターミナル", empty: "ターミナルなし"),
            (locale: "ko", hosts: "호스트", terminal: "터미널", empty: "터미널 없음"),
            (locale: "zh-Hant", hosts: "主機", terminal: "終端", empty: "暫無終端"),
        ]

        for item in cases {
            let app = XCUIApplication()
            app.launchEnvironment["CONN_DEMO"] = "1"
            app.launchArguments = ["-conn.language", item.locale]
            app.launch()

            XCTAssertTrue(
                app.tabBars.buttons[item.hosts].waitForExistence(timeout: 10),
                "Root package copy did not localize for \(item.locale)"
            )
            let terminalTab = app.tabBars.buttons[item.terminal]
            XCTAssertTrue(terminalTab.exists)
            terminalTab.tap()
            XCTAssertTrue(
                app.staticTexts[item.empty].waitForExistence(timeout: 5),
                "App copy did not localize for \(item.locale)"
            )

            app.terminate()
        }
    }
}
