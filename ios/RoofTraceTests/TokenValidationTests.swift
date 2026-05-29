import XCTest
@testable import RoofTrace

/// Phase 2.1 — written before TokenValidator exists.
/// The capture_token is a Rails `has_secure_token` value: 32-char base58
/// (SecureRandom.base58 — the Bitcoin alphabet, no 0 O I l). The bearer header
/// is exactly "Bearer <token>" with a single space.
final class TokenValidationTests: XCTestCase {
    func test32CharBase58Passes() {
        // 32 chars, all from the base58 alphabet.
        let token = "123456789ABCDEFGHJKLMNPQRSTUVWXY"
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(TokenValidator.isValid(token))
    }

    func testTooShortRejected() {
        XCTAssertFalse(TokenValidator.isValid(String(repeating: "A", count: 31)))
    }

    func testTooLongRejected() {
        XCTAssertFalse(TokenValidator.isValid(String(repeating: "A", count: 33)))
    }

    func testEmptyRejected() {
        XCTAssertFalse(TokenValidator.isValid(""))
    }

    func testNonBase58Rejected() {
        // base58 excludes 0 (zero), O (capital o), I (capital i), l (lower L).
        XCTAssertFalse(TokenValidator.isValid("0000000000000000000000000000000O")) // has 0 and O
        XCTAssertFalse(TokenValidator.isValid("IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII")) // capital I
        XCTAssertFalse(TokenValidator.isValid("llllllllllllllllllllllllllllllll")) // lower L
        XCTAssertFalse(TokenValidator.isValid("++++++++++++++++++++++++++++++++")) // punctuation
    }

    func testJobIDValidUUID() {
        XCTAssertTrue(TokenValidator.isValidJobID("10b00000-0000-4000-8000-000000000002"))
        XCTAssertFalse(TokenValidator.isValidJobID("not-a-uuid"))
        XCTAssertFalse(TokenValidator.isValidJobID(""))
    }

    func testDeepLinkParseExtractsTokenAndJobID() {
        let url = URL(string: "rooftrace://capture?token=123456789ABCDEFGHJKLMNPQRSTUVWXY&job_id=10b00000-0000-4000-8000-000000000002")!
        let parsed = TokenValidator.parseDeepLink(url)
        XCTAssertEqual(parsed?.token, "123456789ABCDEFGHJKLMNPQRSTUVWXY")
        XCTAssertEqual(parsed?.jobID, "10b00000-0000-4000-8000-000000000002")
    }

    func testDeepLinkWrongSchemeReturnsNil() {
        let url = URL(string: "https://capture?token=123456789ABCDEFGHJKLMNPQRSTUVWXY&job_id=10b00000-0000-4000-8000-000000000002")!
        XCTAssertNil(TokenValidator.parseDeepLink(url))
    }

    func testDeepLinkMissingTokenReturnsNil() {
        let url = URL(string: "rooftrace://capture?job_id=10b00000-0000-4000-8000-000000000002")!
        XCTAssertNil(TokenValidator.parseDeepLink(url))
    }

    func testBearerHeaderIsExactlySingleSpace() {
        let token = "123456789ABCDEFGHJKLMNPQRSTUVWXY"
        let header = TokenValidator.bearerHeaderValue(token)
        XCTAssertEqual(header, "Bearer 123456789ABCDEFGHJKLMNPQRSTUVWXY")
        // Exactly one space after "Bearer".
        XCTAssertEqual(header.filter { $0 == " " }.count, 1)
        XCTAssertTrue(header.hasPrefix("Bearer "))
        XCTAssertFalse(header.hasPrefix("Bearer  "))
    }
}
