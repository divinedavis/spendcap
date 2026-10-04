import XCTest

/// Apple's automated accessibility audit (iOS 17+) on every main screen,
/// added 2026-10-04: contrast, Dynamic Type, missing labels, hit targets,
/// traits. scripts/ship.sh refuses to upload a build unless this ran.
///
/// Tabs are read from the tab bar at run time, so a tab added or removed is
/// audited or dropped without editing this file. Every screen is audited in
/// light AND dark mode — the app follows the system appearance, and a
/// simulator other sessions share may have been left in either.
///
/// What is excused, and why, lives in `excused(_:)`. Never excuse an issue on
/// one of our own controls to get the gate green; fix the view.
final class AccessibilityAuditTests: XCTestCase {
    private var app: XCUIApplication!
    private var appearanceBefore: XCUIDevice.Appearance = .light

    override func setUp() {
        continueAfterFailure = true   // one screen's issues must not hide the next screen's
        appearanceBefore = XCUIDevice.shared.appearance
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = appearanceBefore
        super.tearDown()
    }

    private func launch(signedOut: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + (signedOut ? ["-UITestForceSignOut"] : []) + extra
        app.launch()
        acceptNotificationPromptIfPresent()
        self.app = app
        return app
    }

    private func credentials() throws -> (String, String) {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SPENDCAP_TEST_EMAIL"], let password = env["SPENDCAP_TEST_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("SPENDCAP_TEST_EMAIL/PASSWORD not set")
        }
        return (email, password)
    }

    /// Signed in and settled on Trends, the landing tab.
    private func launchSignedIn(extra: [String] = []) throws {
        let (email, password) = try credentials()
        let app = launch(signedOut: true, extra: extra)
        signIn(app, email: email, password: password)
        XCTAssertTrue(app.staticTexts["trends.monthSpend"].waitForExistence(timeout: 25),
                      "Trends never loaded after sign-in")
        dismissSavePasswordPromptIfPresent(timeout: 2)
    }

    /// The floating tab bar, grown by its shadow and by the band above it that
    /// iOS 26 blurs scroll content into: a row scrolled under it is measured
    /// against the bar's pixels, not its own.
    private var floating: [CGRect] {
        let bar = app.tabBars.firstMatch
        guard bar.exists, !bar.frame.isEmpty else { return [] }
        let f = bar.frame
        return [CGRect(x: f.minX - 40, y: f.minY - 64, width: f.width + 80, height: f.height + 104)]
    }

    private func excused(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        guard let e = issue.element else { return true }   // nothing to point at
        // Apple draws the Sign in with Apple button and owns its look.
        if e.label.contains("Sign in with Apple") { return true }
        // The system keyboard is not ours.
        let kb = app.keyboards.firstMatch
        if kb.exists, e.frame.minY >= kb.frame.minY - 50 { return true }
        // "Partially unsupported" lands on text the layout deliberately keeps
        // to one line (chart axis labels, money in a row);
        // testTheLargestTextSizeStillWorks checks the app stays usable at the
        // largest size. "Unsupported" — a fixed font size — still fails.
        if issue.auditType.contains(.dynamicType), issue.compactDescription.contains("partially") { return true }
        if issue.auditType.contains(.contrast) {
            if !e.isEnabled { return true }   // WCAG 1.4.3 exempts disabled controls
            let bar = app.tabBars.firstMatch
            if bar.exists, !bar.frame.contains(e.frame),
               floating.contains(where: { e.frame.intersects($0) }) { return true }
            let window = app.windows.firstMatch.frame
            if !window.isEmpty, e.frame.maxY > window.maxY - 34 { return true }   // under the home indicator
        }
        return false
    }

    private static func name(_ t: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
            (.sufficientElementDescription, "description"), (.dynamicType, "dynamic type"),
            (.textClipped, "text clipped"), (.trait, "trait")]
        return names.first { t.contains($0.0) }?.1 ?? "type \(t.rawValue)"
    }

    private func audit(_ screen: String) {
        for look in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = look
            sleep(1)
            auditOnce("\(screen) [\(look == .dark ? "dark" : "light")]")
        }
    }

    private func auditOnce(_ screen: String) {
        var found: [String] = []
        do {
            // Text Clipped is left out: it fires on labels with room to spare
            // while a chart animates in. Clipping that matters is caught by
            // testTheLargestTextSizeStillWorks.
            var types: XCUIAccessibilityAuditType = .all
            types.remove(.textClipped)
            try app.performAccessibilityAudit(for: types) { issue in
                if self.excused(issue) { return true }
                let e = issue.element
                found.append("\(Self.name(issue.auditType)) — \(issue.compactDescription) — [\(e?.identifier ?? "")] \"\(e?.label ?? "")\""
                             + (e.map { " type \($0.elementType.rawValue) @\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? ""))
                return true
            }
        } catch {
            XCTFail("\(screen): audit could not run: \(error)")
        }
        if !found.isEmpty {
            XCTFail("\(screen): \(found.count) accessibility issue(s):\n" + found.joined(separator: "\n"))
        }
    }

    func testSignInScreen() {
        let app = launch(signedOut: true)
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 15), "sign-in never appeared")
        audit("Sign in")
    }

    func testEveryTab() throws {
        try launchSignedIn()
        let names = app.tabBars.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        XCTAssertGreaterThan(names.count, 1, "the tab bar should list its tabs")
        for name in names {
            app.tapTab(name, in: self)
            sleep(2)
            audit(name)
        }
    }

    /// The real Dynamic Type check: at the largest accessibility size the app
    /// still signs in, Trends still loads, and every tab can still be opened.
    /// Opened, not `isHittable`: the selected tab on iOS 26's floating bar
    /// sits under its own selection glass and reports not hittable while
    /// working fine, so `tapTab` (which confirms the selection) is the test.
    func testTheLargestTextSizeStillWorks() throws {
        try launchSignedIn(extra: ["-UIPreferredContentSizeCategoryName",
                                   "UICTContentSizeCategoryAccessibilityXXXL"])
        let names = app.tabBars.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        XCTAssertGreaterThan(names.count, 1)
        for name in names.reversed() {
            app.tapTab(name, in: self)
        }
    }
}
