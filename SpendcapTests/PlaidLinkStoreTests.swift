import XCTest
@testable import Spendcap

@MainActor
final class PlaidLinkStoreTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Redirect matching

    func testMatchesOAuthRedirect() {
        XCTAssertTrue(PlaidLinkStore.isOAuthRedirect(url("https://divinedavis.com/spendcap/oauth/")))
        XCTAssertTrue(PlaidLinkStore.isOAuthRedirect(url("https://divinedavis.com/spendcap/oauth")))
    }

    func testMatchesRedirectWithPlaidQueryParameters() {
        // Plaid appends state/oauth_state_id on the way back from the bank.
        XCTAssertTrue(PlaidLinkStore.isOAuthRedirect(
            url("https://divinedavis.com/spendcap/oauth/?oauth_state_id=abc-123")))
    }

    func testMatchesWwwSubdomain() {
        XCTAssertTrue(PlaidLinkStore.isOAuthRedirect(url("https://www.divinedavis.com/spendcap/oauth/")))
    }

    /// Hidden Gems universal links live on the same domain and share the same
    /// apple-app-site-association. Spendcap must not claim them.
    func testIgnoresHiddenGemsUniversalLinks() {
        XCTAssertFalse(PlaidLinkStore.isOAuthRedirect(
            url("https://divinedavis.com/hidden-gems/post/abc")))
        XCTAssertFalse(PlaidLinkStore.isOAuthRedirect(
            url("https://divinedavis.com/hidden-gems/folder/xyz")))
    }

    func testIgnoresOtherSiteLinks() {
        XCTAssertFalse(PlaidLinkStore.isOAuthRedirect(url("https://divinedavis.com/")))
        XCTAssertFalse(PlaidLinkStore.isOAuthRedirect(url("https://divinedavis.com/portfolio.html")))
    }

    /// A look-alike host must not be accepted — matching on suffix alone would
    /// wrongly admit notdivinedavis.com, so the check must be anchored.
    func testIgnoresForeignHosts() {
        XCTAssertFalse(PlaidLinkStore.isOAuthRedirect(url("https://evil.com/spendcap/oauth/")))
        XCTAssertFalse(PlaidLinkStore.isOAuthRedirect(url("https://notdivinedavis.com/spendcap/oauth/")))
    }

    // MARK: - Token lifecycle

    func testHandleRequiresASavedToken() {
        let store = PlaidLinkStore.shared
        store.clear()
        // No stored token means there's no flow to resume — ignore the link
        // rather than opening Link with nothing to continue from.
        XCTAssertFalse(store.handle(url: url("https://divinedavis.com/spendcap/oauth/")))
        XCTAssertNil(store.pendingRedirect)
    }

    func testHandleAcceptsRedirectOnceTokenStored() {
        let store = PlaidLinkStore.shared
        store.clear()
        store.remember(token: "link-sandbox-test-token")
        XCTAssertTrue(store.handle(url: url("https://divinedavis.com/spendcap/oauth/")))
        XCTAssertNotNil(store.pendingRedirect)
        store.clear()
    }

    func testClearRemovesTokenAndPendingRedirect() {
        let store = PlaidLinkStore.shared
        store.remember(token: "link-sandbox-test-token")
        _ = store.handle(url: url("https://divinedavis.com/spendcap/oauth/"))
        store.clear()
        XCTAssertNil(store.savedToken)
        XCTAssertNil(store.pendingRedirect)
    }

    func testUnrelatedLinkDoesNotClobberAPendingResume() {
        let store = PlaidLinkStore.shared
        store.clear()
        store.remember(token: "link-sandbox-test-token")
        _ = store.handle(url: url("https://divinedavis.com/spendcap/oauth/"))
        let pending = store.pendingRedirect
        XCTAssertFalse(store.handle(url: url("https://divinedavis.com/hidden-gems/post/abc")))
        XCTAssertEqual(store.pendingRedirect, pending)
        store.clear()
    }
}
