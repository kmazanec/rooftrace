import Foundation

/// One part of a multipart/form-data body.
struct MultipartPart {
    let name: String
    let filename: String
    let contentType: String
    let data: Data
}

/// Assembles a multipart/form-data body from parts. Deterministic byte layout:
/// CRLF line endings, one `--boundary` delimiter per part, a closing
/// `--boundary--` delimiter. Pure value type so it is trivially unit-testable.
struct MultipartEncoder {
    let boundary: String

    init(boundary: String = "----RoofTraceBoundary\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    func encode(_ parts: [MultipartPart]) -> Data {
        var body = Data()
        for part in parts {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(part.filename)\"\r\n")
            body.append("Content-Type: \(part.contentType)\r\n\r\n")
            body.append(part.data)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")
        return body
    }

    /// Streams the encoded body to a temp file (so the full bundle never sits in
    /// RAM during upload). Returns the temp file URL; the caller deletes it.
    func encodeToTempFile(_ parts: [MultipartPart]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rooftrace-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for part in parts {
            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(part.filename)\"\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Type: \(part.contentType)\r\n\r\n".utf8))
            try handle.write(contentsOf: part.data)
            try handle.write(contentsOf: Data("\r\n".utf8))
        }
        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        return url
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

/// A prepared upload: the destination, bearer token, the assembled body (either
/// in-memory bytes or a temp file to stream), the boundary, and the stable
/// session_id (the idempotency key — must NOT change across retries).
struct UploadRequest {
    /// The upload body. Exactly one source is live at a time — illegal states
    /// (both set, or neither set) are now unrepresentable.
    enum Body {
        /// In-memory body (unit tests / small bundles).
        case inMemory(Data)
        /// Temp file to stream from (production); never holds the full body in RAM.
        case file(URL)
    }

    let url: URL
    let token: String
    let body: Body
    let boundary: String
    let sessionID: String

    init(url: URL, token: String, bodyData: Data, boundary: String, sessionID: String) {
        self.url = url
        self.token = token
        self.body = .inMemory(bodyData)
        self.boundary = boundary
        self.sessionID = sessionID
    }

    init(url: URL, token: String, bodyFileURL: URL, boundary: String, sessionID: String) {
        self.url = url
        self.token = token
        self.body = .file(bodyFileURL)
        self.boundary = boundary
        self.sessionID = sessionID
    }
}

enum UploadError: Error, Equatable {
    case retryExhausted
    case unauthorized
    case server(Int)
    case transport
}

/// Uploads the capture bundle with exactly one retry. The body is built once
/// (stable session_id) and re-sent unchanged on retry. Non-2xx is a failure;
/// 401 surfaces as `.unauthorized` so the UI can show the token-expiry message.
final class MultipartUploader {
    private let session: URLSession
    private let retryDelay: TimeInterval

    init(session: URLSession = .shared, retryDelay: TimeInterval = 2.0) {
        self.session = session
        self.retryDelay = retryDelay
    }

    func upload(_ request: UploadRequest) async -> Result<Void, UploadError> {
        let first = await attempt(request)
        switch first {
        case .success:
            return .success(())
        case .failure(.unauthorized):
            // A 401 won't be fixed by a retry — surface immediately.
            return .failure(.unauthorized)
        case .failure:
            if retryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
            let second = await attempt(request)
            switch second {
            case .success:
                return .success(())
            case .failure(.unauthorized):
                return .failure(.unauthorized)
            case .failure:
                return .failure(.retryExhausted)
            }
        }
    }

    private func buildURLRequest(_ request: UploadRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(TokenValidator.bearerHeaderValue(request.token),
                            forHTTPHeaderField: "Authorization")
        urlRequest.setValue("multipart/form-data; boundary=\(request.boundary)",
                            forHTTPHeaderField: "Content-Type")
        return urlRequest
    }

    private func attempt(_ request: UploadRequest) async -> Result<Void, UploadError> {
        let urlRequest = buildURLRequest(request)
        do {
            let (_, response): (Data, URLResponse)
            switch request.body {
            case .file(let fileURL):
                // Stream from the temp file — never holds the full body in RAM.
                (_, response) = try await session.upload(for: urlRequest, fromFile: fileURL)
            case .inMemory(let data):
                (_, response) = try await session.upload(for: urlRequest, from: data)
            }
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport)
            }
            switch http.statusCode {
            case 200..<300:
                return .success(())
            case 401:
                return .failure(.unauthorized)
            default:
                return .failure(.server(http.statusCode))
            }
        } catch {
            return .failure(.transport)
        }
    }
}
