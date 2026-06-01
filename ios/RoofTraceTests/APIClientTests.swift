import XCTest
@testable import RoofTrace

final class APIClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(token: String? = "app-token") -> APIClient {
        APIClient(
            baseURL: URL(string: "http://example.test")!,
            session: makeSession(),
            tokenStore: FakeTokenStore(token: token)
        )
    }

    func testDecodesSuccessfulResponseAndSkipsBearerForSessionCreate() async throws {
        StubURLProtocol.responses = [
            .success(statusCode: 200, body: Data(#"{"app_token":"abc","expires_at":"2026-05-31T12:34:56Z"}"#.utf8))
        ]
        let response: SessionResponse = try await makeClient().send(.createSession(username: "u", password: "p"))
        XCTAssertEqual(response.appToken, "abc")
        XCTAssertNil(StubURLProtocol.lastAuthorization)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/v1/sessions")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func testInjectsBearerForAuthenticatedEndpoints() async throws {
        StubURLProtocol.responses = [
            .success(statusCode: 200, body: Data(#"{"jobs":[]}"#.utf8))
        ]
        let _: JobsResponse = try await makeClient(token: "secret").send(.jobs())
        XCTAssertEqual(StubURLProtocol.lastAuthorization, "Bearer secret")
    }

    func testMapsStatusCodesToAPIError() async {
        await assertStatus(401, mapsTo: .unauthorized)
        await assertStatus(404, mapsTo: .notFound)
        await assertStatus(503, mapsTo: .server(503))
    }

    func testBadJSONMapsToDecoding() async {
        StubURLProtocol.reset()
        StubURLProtocol.responses = [.success(statusCode: 200, body: Data("nope".utf8))]
        do {
            let _: JobsResponse = try await makeClient().send(.jobs())
            XCTFail("expected decoding error")
        } catch let error as APIError {
            XCTAssertEqual(error, .decoding)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    private func assertStatus(_ status: Int, mapsTo expected: APIError) async {
        StubURLProtocol.reset()
        StubURLProtocol.responses = [.success(statusCode: status, body: Data(#"{"error":"x"}"#.utf8))]
        do {
            let _: JobsResponse = try await makeClient().send(.jobs())
            XCTFail("expected error for \(status)")
        } catch let error as APIError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
