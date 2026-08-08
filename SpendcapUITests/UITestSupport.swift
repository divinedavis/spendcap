import XCTest

extension XCTestCase {

    /// Scrolls Settings until a row exists, and returns it.
    ///
    /// A SwiftUI `Form` is a lazy `List`: rows below the fold are not merely
    /// off screen, they are absent from the accessibility hierarchy, so
    /// `waitForExistence` on one of them waits out its whole timeout and then
    /// fails. Sign Out and Delete Account live at the very bottom, and the
    /// Account section added with Apple/Google sign-in pushed them past the
    /// fold on a 6.1" simulator — which broke two passing tests without
    /// anything being wrong with the app.
    @discardableResult
    func scrollToSettingsRow(_ app: XCUIApplication, _ identifier: String,
                             file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = app.buttons[identifier]
        for _ in 0..<8 where !row.exists {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "\(identifier) never appeared in Settings, even after scrolling",
                      file: file, line: line)
        return row
    }

    /// Dismisses the "Save Password?" sheet iOS raises after a credential submit.
    ///
    /// It renders above the app, so any tap aimed at the app — a tab, a button —
    /// lands on the sheet instead and is silently swallowed. It also appears
    /// *asynchronously*, often a beat after the post-sign-in screen has already
    /// rendered, so dismissing once right after submit is not enough; call this
    /// again immediately before any navigation.
    ///
    /// `addUIInterruptionMonitor` does not reliably fire for this sheet, so tap
    /// it directly. No-op when nothing is showing.
    /// Signs in with the test account and clears the password prompt.
    ///
    /// Every signed-in test used to inline this, and every one of them was
    /// intermittently failing with "Neither element nor any descendant has
    /// keyboard focus" — the tap on the field lands, focus does not follow,
    /// and `typeText` throws. Nothing about the app is wrong when that
    /// happens; the fix is to wait for focus rather than assume the tap gave
    /// it, which `focusAndType` does.
    func signIn(_ app: XCUIApplication, email: String, password: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15),
                      "auth screen should appear", file: file, line: line)
        emailField.focusAndType(email, file: file, line: line)
        app.secureTextFields["auth.password"].focusAndType(password, file: file, line: line)
        app.buttons["auth.submit"].tap()
        dismissSavePasswordPromptIfPresent()
    }

    @discardableResult
    func dismissSavePasswordPromptIfPresent(timeout: TimeInterval = 0) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = [
            springboard.buttons["Not Now"],
            springboard.alerts.buttons["Not Now"],
            springboard.sheets.buttons["Not Now"],
        ]
        for button in candidates {
            let present = timeout > 0
                ? button.waitForExistence(timeout: timeout)
                : button.exists
            if present, button.isHittable {
                button.tap()
                return true
            }
        }
        return false
    }
}

extension XCUIElement {

    /// Taps a text field and types, but only once the field reports keyboard
    /// focus — `typeText` throws outright without it, and a tap does not
    /// reliably confer it on iOS 26. Retries the tap, since the first one is
    /// the one that usually gets lost.
    func focusAndType(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<4 {
            tap()
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                // Undocumented, but it is the only way to ask; the alternative
                // is to type and hope.
                if (value(forKey: "hasKeyboardFocus") as? Bool) == true {
                    typeText(text)
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        XCTFail("field never took keyboard focus", file: file, line: line)
    }
}

extension XCUIApplication {

    /// Selects a tab and waits until it actually becomes selected.
    ///
    /// `element.tap()` on iOS 26's floating tab bar frequently does **not**
    /// switch tabs — the element is hittable and the tap reports success, but
    /// the selection never changes (verified: after tapping "Trends" the app is
    /// still on Home with Home `Selected`). Tapping the element's centre
    /// coordinate does work, so fall back to that and confirm via `isSelected`
    /// rather than trusting the tap.
    func tapTab(_ name: String, in testCase: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        let tab = tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10),
                      "\(name) tab should exist", file: file, line: line)

        if tab.isSelected { return }

        for attempt in 0..<3 {
            testCase.dismissSavePasswordPromptIfPresent()

            if attempt == 0 {
                tab.tap()
            } else {
                tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }

            // Selection is applied on the next runloop turn; poll briefly.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if tab.isSelected { return }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        XCTFail("\(name) tab never became selected after 3 attempts", file: file, line: line)
    }
}
