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

    /// Full round trip: sign in with the keychain test account, open the budget
    /// sheet from Home, then sign out. Skipped when creds are absent.
    func testSignInShowsHomeAndBudgetSheet() throws {
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

        // Sign-in lands on Home, which is where the cap is now adjusted — the
        // Today tab (and its toolbar button) is gone.
        XCTAssertTrue(app.staticTexts["home.remaining"].waitForExistence(timeout: 20),
                      "Home hero card should appear after sign-in")

        app.buttons["home.adjustCap"].tap()
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

        // Months took the slot Today used to hold.
        app.tapTab("Months", in: self)
        XCTAssertTrue(app.staticTexts["months.total"].waitForExistence(timeout: 20),
                      "Months should show the 12-month total")
    }

    /// The Months tab renders whichever of its two states applies: the totals
    /// when the bank has shared history, or the "no monthly history yet" copy
    /// when it hasn't. The test account has no linked bank, so this exercises
    /// the empty path — the total tile is always present either way, and the
    /// screen must settle rather than hang on a spinner. Skipped when creds are
    /// absent.
    func testMonthsTabShowsTwelveMonthTotal() throws {
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

        XCTAssertTrue(app.staticTexts["home.remaining"].waitForExistence(timeout: 20),
                      "Home hero card should appear after sign-in")

        app.tapTab("Months", in: self)

        XCTAssertTrue(app.navigationBars["Months"].waitForExistence(timeout: 15),
                      "Months screen should appear")
        XCTAssertTrue(app.staticTexts["months.total"].waitForExistence(timeout: 20),
                      "Months should show a 12-month total in both states")

        // Today is gone for good — a stale tab left in place would keep
        // showing a partial daily figure this change exists to retire.
        XCTAssertFalse(app.buttons["Today"].exists, "Today tab should no longer exist")
    }

    /// Statements is reachable from Settings and renders one of its two valid
    /// states. The test account has no linked bank, so this exercises the
    /// "nothing to show" path — the screen must still appear rather than hang
    /// on a spinner or crash on an empty list. Skipped when creds are absent.
    func testStatementsScreenIsReachable() throws {
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

        XCTAssertTrue(app.staticTexts["home.remaining"].waitForExistence(timeout: 20),
                      "Home hero card should appear after sign-in")

        app.tapTab("Settings", in: self)

        let statementsRow = app.buttons["settings.statements"]
        if !statementsRow.waitForExistence(timeout: 5) {
            app.tapTab("Settings", in: self)   // same dismissal race the sign-out test guards
            XCTAssertTrue(statementsRow.waitForExistence(timeout: 10),
                          "Statements row should exist in Settings")
        }
        statementsRow.tap()

        XCTAssertTrue(app.navigationBars["Statements"].waitForExistence(timeout: 15),
                      "Statements screen should push onto the navigation stack")

        // Either state is correct here: the approval prompt when the bank has
        // not consented, or the empty-state when it has but nothing is stored.
        // Asserting on one specific copy string would make this brittle.
        let approve = app.buttons["statements.approve"]
        let refresh = app.buttons["statements.refresh"]
        // Poll for whichever resolves first; XCTest has no built-in "wait for
        // any of these elements", and two unwaited expectations would fail the
        // test on their own.
        let deadline = Date().addingTimeInterval(20)
        var resolved = false
        while Date() < deadline {
            if approve.exists || refresh.exists { resolved = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(resolved, "Statements should settle into either the consent prompt or the list")
    }
}
