import XCTest
@testable import Spendcap

final class SocialIdentityTests: XCTestCase {

    private let email = LinkedIdentity(provider: "email", email: "a@b.com")
    private let apple = LinkedIdentity(provider: "apple", email: "relay@privaterelay.appleid.com")
    private let google = LinkedIdentity(provider: "google", email: "a@b.com")

    // MARK: - Provider keys

    /// These strings are what Supabase writes into auth.identities.provider.
    /// If a rename ever changes them, every "is this linked?" check silently
    /// answers no and the UI offers to link an already-linked provider.
    func testProviderKeysMatchSupabase() {
        XCTAssertEqual(SocialProvider.apple.key, "apple")
        XCTAssertEqual(SocialProvider.google.key, "google")
    }

    func testLinkedIdentityMapsKnownProviders() {
        XCTAssertEqual(apple.socialProvider, .apple)
        XCTAssertEqual(google.socialProvider, .google)
        XCTAssertNil(email.socialProvider, "email is not a social provider")
    }

    // MARK: - isLinked / linkable

    func testIsLinked() {
        XCTAssertTrue(IdentityRules.isLinked(.apple, in: [email, apple]))
        XCTAssertFalse(IdentityRules.isLinked(.google, in: [email, apple]))
    }

    func testLinkableExcludesAlreadyLinkedAndKeepsOrder() {
        XCTAssertEqual(IdentityRules.linkable(from: [email]), [.apple, .google])
        XCTAssertEqual(IdentityRules.linkable(from: [email, apple]), [.google])
        XCTAssertEqual(IdentityRules.linkable(from: [email, apple, google]), [])
    }

    // MARK: - canUnlink — the one that can lock someone out

    /// The account holds real bank history and a Plaid Item that permanently
    /// consumed one of ten Trial slots. Removing the only identity leaves it
    /// unreachable forever, and Supabase will do it if asked.
    func testCannotUnlinkTheOnlyIdentity() {
        XCTAssertFalse(IdentityRules.canUnlink(.apple, from: [apple]))
        XCTAssertFalse(IdentityRules.canUnlink(.google, from: [google]))
    }

    func testCanUnlinkWhenAnotherWayInExists() {
        XCTAssertTrue(IdentityRules.canUnlink(.apple, from: [email, apple]))
        XCTAssertTrue(IdentityRules.canUnlink(.google, from: [apple, google]))
    }

    func testCannotUnlinkSomethingNotLinked() {
        XCTAssertFalse(IdentityRules.canUnlink(.google, from: [email, apple]))
    }

    func testUnlinkableWhenEmpty() {
        XCTAssertFalse(IdentityRules.canUnlink(.apple, from: []))
    }

    // MARK: - Summary

    func testSummary() {
        XCTAssertEqual(IdentityRules.summary([]), "None")
        XCTAssertEqual(IdentityRules.summary([email]), "Email")
        XCTAssertEqual(IdentityRules.summary([email, apple, google]), "Email, Apple, Google")
    }

    // MARK: - Nonce

    func testNonceLengthAndCharset() {
        let allowed = CharacterSet(charactersIn:
            "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        for length in [1, 16, 32, 64] {
            let nonce = AuthNonce.random(length: length)
            XCTAssertEqual(nonce.count, length)
            XCTAssertNil(nonce.rangeOfCharacter(from: allowed.inverted),
                         "nonce must stay URL-safe: \(nonce)")
        }
    }

    func testNoncesAreDistinct() {
        let nonces = Set((0..<200).map { _ in AuthNonce.random() })
        XCTAssertEqual(nonces.count, 200, "a repeated nonce means the RNG isn't")
    }

    /// Apple signs SHA-256(nonce) into the token's `nonce` claim and Supabase
    /// re-hashes the raw value we send. A pinned vector catches any change to
    /// the digest encoding — lowercase hex, no separators — which would fail
    /// verification with an error that says nothing about the nonce.
    func testSha256MatchesKnownVector() {
        XCTAssertEqual(
            AuthNonce.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            AuthNonce.sha256(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    // MARK: - ID token claims
    //
    // Sign in with Apple failed on build 28 with GoTrue's
    // "Passed nonce and nonce in id_token should either both exist or not."
    // We had asked Apple for a nonce and sent the raw value, but the returned
    // token carried no nonce claim. What we send now depends on reading that
    // claim correctly, so the decoding is pinned here.

    /// Builds an unsigned JWT with the given payload, base64url, unpadded —
    /// the encoding Apple actually uses.
    private func makeToken(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let body = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(body).signature"
    }

    func testReadsNonceClaimWhenPresent() {
        let token = makeToken(["nonce": "abc123", "sub": "u1"])
        XCTAssertEqual(IDToken.stringClaim("nonce", from: token), "abc123")
        XCTAssertEqual(IDToken.stringClaim("sub", from: token), "u1")
    }

    /// The case that broke sign-in: nonce absent, so none may be sent.
    func testMissingNonceClaimReadsAsNil() {
        let token = makeToken(["sub": "u1", "email": "a@b.com"])
        XCTAssertNil(IDToken.stringClaim("nonce", from: token))
    }

    /// An empty claim is as good as absent — sending a nonce against it would
    /// hit the same GoTrue rejection.
    func testEmptyClaimReadsAsNil() {
        XCTAssertNil(IDToken.stringClaim("nonce", from: makeToken(["nonce": ""])))
    }

    func testNonStringClaimReadsAsNil() {
        XCTAssertNil(IDToken.stringClaim("nonce", from: makeToken(["nonce": 42])))
    }

    /// base64url drops padding, and payload lengths vary — every remainder
    /// mod 4 has to decode or the claim reads as absent at random.
    func testDecodesPayloadsOfEveryPaddingLength() {
        for extra in 0..<4 {
            let token = makeToken(["nonce": "n", "pad": String(repeating: "x", count: extra)])
            XCTAssertEqual(IDToken.stringClaim("nonce", from: token), "n",
                           "padding remainder \(extra) failed to decode")
        }
    }

    func testMalformedTokensDoNotCrash() {
        XCTAssertNil(IDToken.stringClaim("nonce", from: ""))
        XCTAssertNil(IDToken.stringClaim("nonce", from: "onlyonepart"))
        XCTAssertNil(IDToken.stringClaim("nonce", from: "a.!!!notbase64!!!.c"))
        XCTAssertNil(IDToken.stringClaim("nonce", from: "a.\("notjson".data(using: .utf8)!.base64EncodedString()).c"))
    }

    func testSha256IsHexAndFixedWidth() {
        let digest = AuthNonce.sha256(AuthNonce.random())
        XCTAssertEqual(digest.count, 64)
        XCTAssertNil(digest.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted))
    }
}
