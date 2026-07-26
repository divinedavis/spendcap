import XCTest

extension XCTestCase {

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
