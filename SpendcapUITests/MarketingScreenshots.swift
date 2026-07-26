import XCTest

/// Captures App Store / portfolio screenshots from a signed-in session.
///
/// Skipped unless `SPENDCAP_SCREENSHOTS=1`, so it stays out of the normal
/// `run_tests.sh` sweep — it's a capture run, not an assertion suite.
/// Invoke with `./scripts/capture_screenshots.sh`, which pulls the PNGs out of
/// the result bundle.
final class MarketingScreenshots: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureScreens() throws {
        guard ProcessInfo.processInfo.environment["SPENDCAP_SCREENSHOTS"] == "1" else {
            throw XCTSkip("set SPENDCAP_SCREENSHOTS=1 to capture screenshots")
        }
        guard let email = ProcessInfo.processInfo.environment["SPENDCAP_TEST_EMAIL"],
              let password = ProcessInfo.processInfo.environment["SPENDCAP_TEST_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("SPENDCAP_TEST_EMAIL/PASSWORD not set")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestForceSignOut"]
        app.launch()

        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        save(app, "01-signin")

        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["auth.password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["auth.submit"].tap()
        dismissSavePasswordPromptIfPresent()

        // Home is the landing tab.
        XCTAssertTrue(app.staticTexts["home.remaining"].waitForExistence(timeout: 30),
                      "Home hero card should appear after sign-in")
        save(app, "02-home")

        app.tapTab("Trends", in: self)
        if true {
            if app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20) {
                save(app, "03-trends-spending")
                // Capture the other two chart modes from the segmented control.
                for (index, label) in ["Daily", "Target"].enumerated() {
                    let segment = app.buttons[label]
                    if segment.waitForExistence(timeout: 5) {
                        segment.tap()
                        save(app, "0\(4 + index)-trends-\(label.lowercased())")
                    }
                }
            }
        }

        app.tapTab("Today", in: self)
        XCTAssertTrue(app.staticTexts["today.spent"].waitForExistence(timeout: 30),
                      "Today ring should appear")
        save(app, "06-today")

        app.buttons["today.editBudget"].tap()
        let limitField = app.descendants(matching: .any)
            .matching(identifier: "budget.dailyLimit").firstMatch
        if limitField.waitForExistence(timeout: 10) {
            save(app, "07-budget")
            app.buttons["Cancel"].tap()
        }

        app.tapTab("Settings", in: self)
        if true {
            if app.buttons["settings.signOut"].waitForExistence(timeout: 10) {
                save(app, "08-settings")
            }
        }
    }
}
