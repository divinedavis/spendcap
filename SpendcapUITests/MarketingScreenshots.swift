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

        // Trends is the landing tab.
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 30),
                      "Trends should appear after sign-in")
        save(app, "02-trends")

        if true {
            if app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20) {
                save(app, "03-trends-spending")
                // Capture the other chart mode from the segmented control.
                //
                // Existence is not enough here: the segments exist while the
                // chart is still laying out, and tapping one then fails as
                // "not hittable" — which aborted the whole capture run before
                // it reached the later tabs. Wait for hittability, and treat a
                // segment that never settles as a missing screenshot rather
                // than a failed run. This is a capture, not an assertion suite.
                for (index, label) in ["Daily"].enumerated() {
                    let segment = app.buttons[label]
                    guard segment.waitForExistence(timeout: 5) else { continue }
                    let deadline = Date().addingTimeInterval(10)
                    while !segment.isHittable && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                    guard segment.isHittable else { continue }
                    segment.tap()
                    save(app, "0\(4 + index)-trends-\(label.lowercased())")
                }
            }
        }

        app.tapTab("Activity", in: self)
        if app.staticTexts["activity.total"].waitForExistence(timeout: 30) {
            save(app, "06-activity")
        }

        app.tapTab("Months", in: self)
        XCTAssertTrue(app.staticTexts["months.total"].waitForExistence(timeout: 30),
                      "Months total should appear")
        save(app, "07-months")

        app.buttons["months.editCap"].tap()
        let limitField = app.descendants(matching: .any)
            .matching(identifier: "budget.dailyLimit").firstMatch
        if limitField.waitForExistence(timeout: 10) {
            save(app, "07-budget")
            app.buttons["Cancel"].tap()
        }

        // Debt: the tab that says what is going out every month, grouped, with
        // a subtotal per group. Shot before Trips because it is a tab now and
        // Trips is not.
        app.tapTab("Debt", in: self)
        if app.staticTexts["debt.total"].waitForExistence(timeout: 20) {
            save(app, "08-debt")
        }

        // Trips: both states are worth having. The empty state explains what a
        // trip is for, and a real one shows planned against actual — which is
        // the screenshot that says what the screen does. It opens from Settings
        // now, not from a tab.
        app.tapTab("Settings", in: self)
        scrollToSettingsRow(app, "settings.trips").tap()
        if app.navigationBars["Trips"].waitForExistence(timeout: 20) {
            save(app, "09-trips")

            if app.buttons["trips.new"].waitForExistence(timeout: 10) {
                app.buttons["trips.new"].tap()
                let name = app.textFields["trip.name"]
                if name.waitForExistence(timeout: 15) {
                    name.tap()
                    name.typeText("Tokyo")
                    save(app, "10-trip-new")
                    app.buttons["trip.save"].tap()

                    if app.staticTexts["trip.spent"].waitForExistence(timeout: 25) {
                        // Tick one line off so the shot shows both states.
                        let check = app.buttons.matching(identifier: "trip.lineCheck").firstMatch
                        if check.waitForExistence(timeout: 10) {
                            check.tap()
                            _ = app.staticTexts["trip.settledCount"].waitForExistence(timeout: 10)
                        }
                        save(app, "11-trip-detail")
                        // Leave nothing behind: the account is shared with the
                        // assertion suite, and a stray trip changes what it sees.
                        if app.buttons["trip.delete"].waitForExistence(timeout: 10) {
                            app.buttons["trip.delete"].tap()
                            app.buttons["Delete"].firstMatch.tap()
                            _ = app.navigationBars["Trips"].waitForExistence(timeout: 15)
                        }
                    }
                }
            }
        }

        // Trips is a sheet now — close it before shooting Settings underneath.
        if app.buttons["trips.done"].waitForExistence(timeout: 5) {
            app.buttons["trips.done"].tap()
        }

        app.tapTab("Settings", in: self)
        if true {
            if app.buttons["settings.signOut"].waitForExistence(timeout: 10) {
                save(app, "12-settings")
            }
        }
    }
}
