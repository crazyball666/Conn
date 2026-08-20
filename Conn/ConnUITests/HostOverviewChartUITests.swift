import XCTest

final class HostOverviewChartUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSystemMetricTogglesChartVisibility() {
        let app = launchOverview()
        let systemMetric = app.buttons["cpu.metric.system"]

        XCTAssertTrue(systemMetric.waitForExistence(timeout: 10))
        scrollToElement(systemMetric, in: app)
        XCTAssertEqual(systemMetric.value as? String, "visible")

        systemMetric.tap()

        XCTAssertEqual(systemMetric.value as? String, "hidden")

        systemMetric.tap()

        XCTAssertEqual(systemMetric.value as? String, "visible")
    }

    @MainActor
    func testHidingAllMetricsShowsEmptyState() {
        let app = launchOverview()
        let metricIDs = ["user", "system", "iowait", "idle", "nice", "irq", "softirq", "steal"]

        for metricID in metricIDs {
            let metric = app.buttons["cpu.metric.\(metricID)"]
            XCTAssertTrue(metric.waitForExistence(timeout: 10))
            scrollToElement(metric, in: app)
            metric.tap()
        }

        XCTAssertTrue(app.staticTexts["cpu.chart.empty"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDarwinOverviewShowsNormalizedSystemAndAPFSUsage() {
        let app = launchOverview(darwin: true)

        XCTAssertTrue(app.staticTexts["macOS 26.0 (25A123)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["部分主机指标不可用"].exists)

        let diskUsage = app.staticTexts["381 G / 477 G"]
        XCTAssertTrue(diskUsage.waitForExistence(timeout: 10))
        scrollToElement(diskUsage, in: app)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func launchOverview(darwin: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_DETAIL"] = "1"
        if darwin {
            app.launchEnvironment["CONN_SMOKE_DARWIN_METRICS"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor
    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable, attempts < 5 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.isHittable)
    }
}
