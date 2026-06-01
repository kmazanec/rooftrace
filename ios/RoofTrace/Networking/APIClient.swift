import Foundation

protocol APIClientProtocol: Sendable {
    func send<Response: Decodable>(_ endpoint: Endpoint<Response>) async throws -> Response
}

extension APIClientProtocol {
    func createSession(username: String, password: String) async throws -> SessionResponse {
        try await send(.createSession(username: username, password: password))
    }

    func jobs() async throws -> [JobSummary] {
        try await send(.jobs()).jobs
    }

    func job(id: String) async throws -> JobStatusResponse {
        try await send(.job(id: id))
    }

    func createJob(address: String) async throws -> CreateJobResponse {
        try await send(.createJob(address: address))
    }

    func report(id: String) async throws -> RoofExport {
        try await send(.report(id: id))
    }
}

actor APIClient: APIClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: any TokenStoring
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenStore: any TokenStoring,
        decoder: JSONDecoder = .roofTraceAPI,
        encoder: JSONEncoder = .roofTraceAPI
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.decoder = decoder
        self.encoder = encoder
    }

    func send<Response: Decodable>(_ endpoint: Endpoint<Response>) async throws -> Response {
        let request = try await makeRequest(endpoint)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport
        }

        switch http.statusCode {
        case 200..<300:
            if Response.self == Data.self, let dataResponse = data as? Response {
                return dataResponse
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw APIError.decoding
            }
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 500...599:
            throw APIError.server(http.statusCode)
        default:
            throw APIError.server(http.statusCode)
        }
    }

    private func makeRequest<Response: Decodable>(_ endpoint: Endpoint<Response>) async throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.transport
        }
        components.path = endpoint.path
        guard let url = components.url else {
            throw APIError.transport
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(AnyEncodable(body))
            } catch {
                throw APIError.transport
            }
        }
        if endpoint.requiresAuth, let token = try await tokenStore.loadToken() {
            request.setValue(TokenValidator.bearerHeaderValue(token), forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

extension JSONDecoder {
    static var roofTraceAPI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.roofTraceFractional.date(from: value) {
                return date
            }
            if let date = ISO8601DateFormatter.roofTraceWholeSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO8601 date string"
            )
        }
        return decoder
    }
}

extension JSONEncoder {
    static var roofTraceAPI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension ISO8601DateFormatter {
    static let roofTraceFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let roofTraceWholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
