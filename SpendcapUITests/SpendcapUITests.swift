import XCTest

final class SpendcapUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(signedOut: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + (signedOut ? ["-UITestForceSignOut"] : [])
        // Forward test-account creds (stripped TEST_RUNNER_ prefix) to the app.
        for key in ["SPENDCAP_TEST_EMAIL", "SPENDCAP_TEST_PASSWORD"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
        return app
    }

    /// Smoke: app launches and lands on the auth screen when signed out.
    func testLaunchShowsAuthScreen() throws {
        let app = launch()
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 15),
                      "auth email field should appear on a signed-out launch")
        XCTAssertTrue(app.secureTextFields["auth.password"].exists)
        XCTAssertTrue(app.buttons["auth.submit"].exists)
    }

    /// Full round trip: sign in with the keychain test account, land on Today,
    /// open the budget sheet, then sign out. Skipped when creds are absent.
    func testSignInShowsTodayAndBudgetSheet() throws {
        guard let email = ProcessInfo.processInfo.environment["SPENDCAP_TEST_EMAIL"],
              let password = ProcessInfo.processInfo.environment["SPENDCAP_TEST_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("SPENDCAP_TEST_EMAIL/PASSWORD not set")
        }

        let app = launch()
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["auth.password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["auth.submit"].tap()
        dismissSavePasswordPromptIfPresent()

        // Sign-in lands on Home; the ring lives on the Today tab.
        XCTAssertTrue(app.staticTexts["home.remaining"].waitForExistence(timeout: 20),
                      "Home hero card should appear after sign-in")

        app.tapTab("Today", in: self)

        let spent = app.staticTexts["today.spent"]
        XCTAssertTrue(spent.waitForExistence(timeout: 20), "Today ring should appear on the Today tab")

        app.buttons["today.editBudget"].tap()
        // Form rows can merge accessibility children, so match any element kind.
        let limitField = app.descendants(matching: .any)
            .matching(identifier: "budget.dailyLimit").firstMatch
        XCTAssertTrue(limitField.waitForExistence(timeout: 10),
                      "budget sheet should show the daily-limit field")

        // A tap during the sheet's presentation animation can miss, so verify
        // the dismissal took and retry once.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        if !limitField.waitForNonExistence(timeout: 5) {
            cancel.tap()
            XCTAssertTrue(limitField.waitForNonExistence(timeout: 10),
                          "budget sheet should dismiss on Cancel")
        }

        app.tapTab("Settings", in: self)

        let signOut = app.buttons["settings.signOut"]
        if !signOut.waitForExistence(timeout: 5) {
            app.tapTab("Settings", in: self)   // retry once — dismissal races are flaky in CI sims
            XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        }
        signOut.tap()
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 15),
                      "should return to auth screen after sign-out")
    }

    /// Home and Trends render with live data, and every Trends chart mode is
    /// reachable. Skipped when creds are absent.
    func testHomeAndTrendsTabs() throws {
        guard let email = ProcessInfo.processInfo.environment["SPENDCAP_TEST_EMAIL"],
              let password = ProcessInfo.processInfo.environment["SPENDCAP_TEST_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("SPENDCAP_TEST_EMAIL/PASSWORD not set")
        }

        let app = launch()
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["auth.password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["auth.submit"].tap()
        dismissSavePasswordPromptIfPresent()

        // Home: hero card shows what's left today, and both pills are live.
        XCTAssertTrue(app.staticTexts["home.remaining"].waitForExistence(timeout: 20),
                      "Home hero card should show the remaining figure")
        XCTAssertTrue(app.buttons["home.adjustCap"].exists)
        XCTAssertTrue(app.buttons["home.addBank"].exists)

        // Trends: month total plus all three chart modes.
        app.tapTab("Trends", in: self)
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20),
                      "Trends should show month-to-date spend")

        for label in ["Daily", "Target", "Spending"] {
            let segment = app.buttons[label]
            XCTAssertTrue(segment.waitForExistence(timeout: 5), "\(label) segment should exist")
            segment.tap()
            XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 10),
                          "month spend should survive switching to \(label)")
        }

        // Today still reachable now that it's no longer the landing tab.
        app.tapTab("Today", in: self)
        XCTAssertTrue(app.staticTexts["today.spent"].waitForExistence(timeout: 20),
                      "Today ring should still be reachable")
    }
}
