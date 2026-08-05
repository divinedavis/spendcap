import XCTest
@testable import Spendcap

/// The rule that decides what a cold start draws.
///
/// The bug these guard: `restoring` used to be folded into `signedOut`, so an
/// already-signed-in launch rendered the sign-in screen until the auth stream
/// caught up — which, before `emitLocalSessionAsInitialSession`, meant a full
/// network round trip.
final class AuthPhaseTests: XCTestCase {

    func testUnresolvedWithoutSessionIsRestoringNotSignedOut() {
        XCTAssertEqual(
            AuthPhase.resolve(hasSession: false, didResolveInitialSession: false),
            .restoring,
            "an unanswered session lookup must not be drawn as signed out"
        )
    }

    func testResolvedWithoutSessionIsSignedOut() {
        XCTAssertEqual(
            AuthPhase.resolve(hasSession: false, didResolveInitialSession: true),
            .signedOut
        )
    }

    func testSessionIsSignedInEvenBeforeTheStreamReports() {
        // Seeded from `currentSession` at init: the session is the answer, so
        // there is nothing left to wait for.
        XCTAssertEqual(
            AuthPhase.resolve(hasSession: true, didResolveInitialSession: false),
            .signedIn
        )
    }

    func testSessionIsSignedInOnceResolved() {
        XCTAssertEqual(
            AuthPhase.resolve(hasSession: true, didResolveInitialSession: true),
            .signedIn
        )
    }

    /// Signing out is a resolved state, not a return to restoring — otherwise
    /// tapping Sign Out would park the user on a blank screen.
    func testSignOutAfterResolvingLandsOnSignedOut() {
        var hasSession = true
        let resolved = true
        XCTAssertEqual(AuthPhase.resolve(hasSession: hasSession, didResolveInitialSession: resolved), .signedIn)
        hasSession = false
        XCTAssertEqual(AuthPhase.resolve(hasSession: hasSession, didResolveInitialSession: resolved), .signedOut)
    }
}
