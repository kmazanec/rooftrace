import XCTest
@testable import RoofTrace

@MainActor
final class AuthStoreTests: XCTestCase {
    func testBootstrapAuthenticatesWhenTokenExists() async {
        let tokens = FakeTokenStore(token: "stored")
        let auth = AuthStore(
            api: FakeAPIClient(result: .failure(APIError.unauthorized)),
            tokenStore: tokens
        )
        await auth.bootstrap()
        XCTAssertTrue(auth.isAuthenticated)
    }

    func testSignInStoresTokenAndAuthenticates() async throws {
        let tokens = FakeTokenStore()
        let response = SessionResponse(appToken: "new-token", expiresAt: Date())
        let auth = AuthStore(api: FakeAPIClient(result: .success(response)), tokenStore: tokens)

        try await auth.signIn(username: "u", password: "p")

        XCTAssertTrue(auth.isAuthenticated)
        let snapshot = await tokens.snapshot()
        XCTAssertEqual(snapshot.token, "new-token")
        XCTAssertEqual(snapshot.storeCount, 1)
    }

    func testUnauthorizedClearsOnceAcrossConcurrentCalls() async {
        let tokens = FakeTokenStore(token: "stored")
        let auth = AuthStore(
            api: FakeAPIClient(result: .failure(APIError.unauthorized)),
            tokenStore: tokens
        )
        await auth.bootstrap()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await auth.handleUnauthorized()
                }
            }
        }

        XCTAssertFalse(auth.isAuthenticated)
        let snapshot = await tokens.snapshot()
        XCTAssertNil(snapshot.token)
        XCTAssertEqual(snapshot.clearCount, 1)
    }
}
