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

    /// Full round trip: sign in with the keychain test account, open the cap
    /// sheet from Months, then sign out. Skipped when creds are absent.
    func testSignInShowsTrendsAndBudgetSheet() throws {
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

        // Sign-in lands on Trends now that Home is gone; the cap is edited
        // from the Months toolbar.
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20),
                      "Trends should be the landing tab after sign-in")

        app.tapTab("Months", in: self)
        app.buttons["months.editCap"].tap()
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

    /// A cold start with a stored session must never show the sign-in screen,
    /// however long the auth stream takes to answer.
    ///
    /// Regression test for the reported bug: `session` began nil and only
    /// filled in once the auth stream reported, so an already-signed-in launch
    /// rendered `AuthView` first — visibly, because the SDK refreshed the
    /// (hour-long) access token over the network before emitting
    /// `.initialSession`.
    ///
    /// The relaunch carries `-UITestSlowAuthRestore`, which holds the stream
    /// back for four seconds. Without it this test passes against the *broken*
    /// build — verified, not assumed: `XCUIApplication.launch()` does not
    /// return until the app has settled, by which point a real flash is long
    /// over, so there is nothing left to catch. Stalling the stream is what
    /// makes the assertion mean anything, and it is the honest simulation: the
    /// bug is what the app draws while the answer is outstanding.
    /// Skipped when creds are absent.
    func testColdRelaunchWithStoredSessionNeverShowsAuthScreen() throws {
        guard let email = ProcessInfo.processInfo.environment["SPENDCAP_TEST_EMAIL"],
              let password = ProcessInfo.processInfo.environment["SPENDCAP_TEST_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("SPENDCAP_TEST_EMAIL/PASSWORD not set")
        }

        // First launch: sign in so a session is written to the keychain.
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
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20),
                      "sign-in should land on Trends before the relaunch")

        // Second launch: same install, session still in the keychain. Note the
        // missing -UITestForceSignOut — that is the whole point.
        app.terminate()
        let signedIn = XCUIApplication()
        signedIn.launchArguments = ["-UITestMode", "-UITestSlowAuthRestore"]
        signedIn.launch()

        // The tabs must already be up while the stream is still stalled. The
        // stored session is read synchronously at init, so there is nothing to
        // wait for: assert on the first look rather than polling, since a
        // `waitForExistence` here would happily pass four seconds late — after
        // a flash the user would have seen.
        let auth = signedIn.textFields["auth.email"]
        XCTAssertFalse(auth.exists,
                       "the sign-in screen must not appear while the session lookup is outstanding")
        XCTAssertTrue(signedIn.tabBars.buttons["Trends"].exists,
                      "a stored session should render the tabs before the auth stream answers")

        // And it must stay that way for the whole stall, not just the first frame.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            XCTAssertFalse(auth.exists,
                           "the sign-in screen must never appear on a launch with a stored session")
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(signedIn.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20),
                      "a stored session should land on Trends with its data")

        // Leave the simulator signed out — every other test forces it anyway,
        // but a stray session makes failures here harder to read.
        signedIn.tapTab("Settings", in: self)
        let signOut = signedIn.buttons["settings.signOut"]
        if !signOut.waitForExistence(timeout: 5) {
            signedIn.tapTab("Settings", in: self)
            XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        }
        signOut.tap()
        XCTAssertTrue(signedIn.textFields["auth.email"].waitForExistence(timeout: 15),
                      "should return to auth screen after sign-out")
    }

    /// Trends renders with live data and every chart mode is reachable, and
    /// Activity lists the month. Skipped when creds are absent.
    func testTrendsAndActivityTabs() throws {
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

        // Trends is the landing tab: month total plus all three chart modes.
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20),
                      "Trends should show month-to-date spend")

        for label in ["Daily", "Target", "Spending"] {
            let segment = app.buttons[label]
            XCTAssertTrue(segment.waitForExistence(timeout: 5), "\(label) segment should exist")
            // Always a coordinate tap. Trends is the landing tab now, so its
            // chart is still laying out as the first tap lands, and isHittable
            // flips between being read and being acted on — checking it first
            // does not help.
            segment.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 10),
                          "month spend should survive switching to \(label)")
        }

        // Activity replaced the Trends slot: the month, transaction by
        // transaction. The test account has no bank, so the total tile is the
        // assertion that holds in both states.
        app.tapTab("Activity", in: self)
        XCTAssertTrue(app.staticTexts["activity.total"].waitForExistence(timeout: 20),
                      "Activity should show the month's total")

        // Months took the slot Today used to hold.
        app.tapTab("Months", in: self)
        XCTAssertTrue(app.staticTexts["months.total"].waitForExistence(timeout: 20),
                      "Months should show the 12-month total")
    }

    /// The Trends period chip offers three months and switching to one takes.
    ///
    /// The chip is a menu now rather than a static "This month" label, and the
    /// screen has to actually follow it — the chart card title is the visible
    /// proof, since the totals depend on the test account's data and the empty
    /// account would make any figure assertion vacuous. Skipped when creds are
    /// absent.
    func testTrendsPeriodFilterOffersThreeMonths() throws {
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

        let title = app.staticTexts["trends.periodTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "Trends should show the period title")
        XCTAssertEqual(title.label, "This month", "Trends should open on the current month")

        // The previous two months are named, so build the expected labels the
        // same way the app does rather than hard-coding month names that would
        // rot on the first of every month.
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        let lastMonth = formatter.string(
            from: calendar.date(byAdding: .month, value: -1, to: Date())!
        )

        // Coordinate tap: the chip is a scroll-view child, and on iOS 26 those
        // report isHittable false while sitting in plain view — the same lie
        // tapTab(_:in:) works around. A plain .tap() fails outright here.
        let chip = app.buttons["trends.period"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the period chip should exist")
        // This one inverts the usual workaround, so don't "fix" it back. A
        // coordinate tap opens a Button but never a SwiftUI Menu — measured:
        // it lands, nothing opens, and neither the app nor SpringBoard shows a
        // menu anywhere in its hierarchy. Only a real .tap() does it. But
        // .tap() checks hittability first, and Trends is the landing tab whose
        // chart is still laying out as the first tap arrives, so that check
        // fails intermittently on a control that is plainly visible a moment
        // later. Hence: settle the frame, then a real tap, then retry.
        var frame = chip.frame
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let next = chip.frame
            if next == frame { break }
            frame = next
        }
        let option = app.buttons[lastMonth]
        for attempt in 0..<3 {
            if attempt == 0, chip.isHittable {
                chip.tap()
            } else {
                chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if option.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(option.exists, "the menu should offer \(lastMonth)")
        if option.isHittable {
            option.tap()
        } else {
            option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        // The whole screen re-reads that month: title, chip and caption.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, title.label != lastMonth {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertEqual(title.label, lastMonth,
                       "picking a month should retitle the chart card")
        XCTAssertTrue(app.staticTexts["Spent"].exists,
                      "a finished month is not still spending 'so far'")
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].exists,
                      "the month total should still render for a past month")
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

        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20),
                      "Trends should appear after sign-in")

        app.tapTab("Months", in: self)

        XCTAssertTrue(app.navigationBars["Months"].waitForExistence(timeout: 15),
                      "Months screen should appear")
        XCTAssertTrue(app.staticTexts["months.total"].waitForExistence(timeout: 20),
                      "Months should show a 12-month total in both states")

        // Today is gone for good — a stale tab left in place would keep
        // showing a partial daily figure this change exists to retire.
        XCTAssertFalse(app.buttons["Today"].exists, "Today tab should no longer exist")
        XCTAssertFalse(app.buttons["Home"].exists, "Home tab should no longer exist")

        // The monthly cap is configurable from this screen: without it the
        // over/under verdict is derived from a daily figure nobody chose.
        app.buttons["months.setCap"].tap()
        let monthlyField = app.descendants(matching: .any)
            .matching(identifier: "budget.monthlyLimit").firstMatch
        XCTAssertTrue(monthlyField.waitForExistence(timeout: 10),
                      "cap sheet should offer a monthly limit field")

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        if !monthlyField.waitForNonExistence(timeout: 5) {
            cancel.tap()   // the same presentation-animation race the budget test guards
            XCTAssertTrue(monthlyField.waitForNonExistence(timeout: 10),
                          "cap sheet should dismiss on Cancel")
        }
    }

    /// The category budget is reachable from Months and settles into one of its
    /// two valid states: the starter-budget prompt when no lines exist, or the
    /// planned-vs-actual list when they do. Asserting on one would make the
    /// test depend on whether the shared test account has been seeded.
    /// Skipped when creds are absent.
    func testCategoryBudgetIsReachableFromMonths() throws {
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

        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20),
                      "Trends should appear after sign-in")

        app.tapTab("Months", in: self)
        XCTAssertTrue(app.staticTexts["months.total"].waitForExistence(timeout: 20))

        // A budget line on Months opens its planned amount for editing. The
        // widget appears only after the category rollup lands, so wait for a
        // row to exist *and* settle — tapping while the card is still being
        // laid out lands the touch wherever the row used to be.
        app.tapTab("Months", in: self)
        let line = app.buttons["months.line"].firstMatch
        if line.waitForExistence(timeout: 20) {
            var frame = line.frame
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.4)
                let next = line.frame
                if next == frame { break }
                frame = next
            }
            // isHittable is unreliable for scroll-view content under the
            // floating tab bar — the same lie tapTab(_:in:) works around — so
            // fall back to the element's own coordinate rather than failing.
            if line.isHittable {
                line.tap()
            } else {
                line.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: "category.planned").firstMatch
                    .waitForExistence(timeout: 10),
                "tapping a budget line should open its planned amount"
            )
            app.buttons["Cancel"].tap()
        }

        // Months carries the breakdown inline, so nothing else there needs tapping.
        // Editing lives in Settings: buttons low in the Months scroll view do
        // not receive taps on iOS 26 — measured by giving one a known-good
        // action and watching nothing happen — so the entry point is a List
        // row, which is the pattern that reliably works.
        // The toolbar entry, re-tested after the layout settles.
        let toolbarEntry = app.buttons["months.openBudget"]
        XCTAssertTrue(toolbarEntry.waitForExistence(timeout: 10))
        toolbarEntry.tap()
        XCTAssertTrue(app.navigationBars["Budget"].waitForExistence(timeout: 15),
                      "Budget should open from the Months toolbar")
        app.buttons["categories.done"].tap()

        app.tapTab("Settings", in: self)
        let entry = app.buttons["settings.categories"]
        if !entry.waitForExistence(timeout: 5) {
            app.tapTab("Settings", in: self)   // same dismissal race the sign-out test guards
            XCTAssertTrue(entry.waitForExistence(timeout: 10),
                          "Settings should list the category budget")
        }
        entry.tap()

        XCTAssertTrue(app.navigationBars["Budget"].waitForExistence(timeout: 15),
                      "Budget screen should push onto the navigation stack")

        // Whichever state it lands in, it must settle rather than spin.
        let actual = app.staticTexts["categories.actual"]
        let seed = app.buttons["categories.seed"]
        let deadline = Date().addingTimeInterval(20)
        var resolved = false
        while Date() < deadline {
            if actual.exists || seed.exists { resolved = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(resolved, "Budget should settle into either the list or the starter prompt")
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

        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 20),
                      "Trends should appear after sign-in")

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
