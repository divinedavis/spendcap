import XCTest

/// Speed and memory on the paths people wait on, added 2026-10-04 with
/// Apple's XCTMetric API. scripts/perf_gate.py fails the ship when a metric is
/// more than 1.5x the median of the last five passing ships
/// (scripts/perf_baseline.json). Simulator numbers catch regressions, not
/// real-world times; those come from MetricKit (Services/MetricsReporter.swift)
/// and the Xcode Organizer (scripts/organizer_report.py).
///
/// Launches are measured signed in, because that is every launch but the
/// first: the session is stored once by `signInOnce()`, then each iteration
/// is a cold start that restores it.
final class PerformanceTests: XCTestCase {
    private let args = ["-UITestMode"]

    private func signInOnce() throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SPENDCAP_TEST_EMAIL"], let password = env["SPENDCAP_TEST_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("SPENDCAP_TEST_EMAIL/PASSWORD not set")
        }
        let app = XCUIApplication()
        app.launchArguments = args + ["-UITestForceSignOut"]
        app.launch()
        acceptNotificationPromptIfPresent()
        signIn(app, email: email, password: password)
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 25))
        dismissSavePasswordPromptIfPresent(timeout: 2)
        app.terminate()
    }

    /// Cold launch to the first frame someone can touch.
    func testLaunch() throws {
        try signInOnce()
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: opts) {
            let app = XCUIApplication(); app.launchArguments = args
            app.launch()
        }
    }

    /// Launch until Trends shows this month's spend: the number people open
    /// the app for.
    func testLaunchToTrends() throws {
        try signInOnce()
        let app = XCUIApplication(); app.launchArguments = args
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: opts) {
            app.launch()
            XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 30))
            app.terminate()
        }
    }

    /// Flinging Trends (chart, budget widget, forecast) and the memory the app
    /// holds with it loaded.
    func testTrendsScroll() throws {
        try signInOnce()
        let app = XCUIApplication(); app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 30))
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        opts.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric(application: app)],
                options: opts) {
            app.swipeUp(velocity: .fast)
            stopMeasuring()
            app.swipeDown(velocity: .fast)
        }
    }
}
