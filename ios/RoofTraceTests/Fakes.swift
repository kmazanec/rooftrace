import Foundation
@testable import RoofTrace

actor FakeTokenStore: TokenStoring {
    var token: String?
    private(set) var storeCount = 0
    private(set) var clearCount = 0

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() async throws -> String? {
        token
    }

    func storeToken(_ token: String) async throws {
        self.token = token
        storeCount += 1
    }

    func clearToken() async throws {
        token = nil
        clearCount += 1
    }

    func snapshot() -> (token: String?, storeCount: Int, clearCount: Int) {
        (token, storeCount, clearCount)
    }
}

final class FakeAPIClient: APIClientProtocol, @unchecked Sendable {
    var results: [Result<Any, Error>]
    private(set) var sentPaths: [String] = []

    init(result: Result<Any, Error>) {
        self.results = [result]
    }

    init(results: [Result<Any, Error>]) {
        self.results = results
    }

    func send<Response: Decodable>(_ endpoint: Endpoint<Response>) async throws -> Response {
        sentPaths.append(endpoint.path)
        let result: Result<Any, Error>
        if results.count > 1 {
            result = results.removeFirst()
        } else if let last = results.last {
            result = last
        } else {
            result = .failure(APIError.transport)
        }
        switch result {
        case .success(let value):
            guard let typed = value as? Response else {
                throw APIError.decoding
            }
            return typed
        case .failure(let error):
            throw error
        }
    }
}
