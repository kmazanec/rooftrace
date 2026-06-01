import XCTest
@testable import RoofTrace

@MainActor
final class LoginViewModelTests: XCTestCase {
    func testSuccessfulLoginStoresTokenAndReplaysStashedRoute() async {
        let tokens = FakeTokenStore()
        let auth = AuthStore(
            api: FakeAPIClient(result: .success(SessionResponse(appToken: "token", expiresAt: Date()))),
            tokenStore: tokens
        )
        let router = AppRouter()
        router.handle(url: URL(string: "rooftrace://jobs/job-1")!, isAuthenticated: false)
        let model = LoginViewModel(auth: auth, router: router)
        model.username = "u"
        model.password = "p"

        await model.signIn()

        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(router.path, [.jobDetail(id: "job-1")])
        XCTAssertNil(model.errorMessage)
    }

    func testUnauthorizedShowsInlineErrorState() async {
        let auth = AuthStore(
            api: FakeAPIClient(result: .failure(APIError.unauthorized)),
            tokenStore: FakeTokenStore()
        )
        let model = LoginViewModel(auth: auth, router: AppRouter())
        model.username = "u"
        model.password = "wrong"

        await model.signIn()

        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(
            model.errorMessage,
            "Those credentials did not match. Check the username and password, then try again."
        )
    }
}
