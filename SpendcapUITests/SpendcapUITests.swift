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

        let spent = app.staticTexts["today.spent"]
        XCTAssertTrue(spent.waitForExistence(timeout: 20), "Today ring should appear after sign-in")

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

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        let signOut = app.buttons["settings.signOut"]
        if !signOut.waitForExistence(timeout: 5) {
            settingsTab.tap()   // retry once — dismissal races are flaky in CI sims
            XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        }
        signOut.tap()
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 15),
                      "should return to auth screen after sign-out")
    }
}
