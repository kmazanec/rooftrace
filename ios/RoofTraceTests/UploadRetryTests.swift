import XCTest
@testable import RoofTrace

/// Phase 2.12 — upload retry behavior via a URLProtocol stub.
/// First attempt fails (no connectivity) -> retry -> 200 = success.
/// Both attempts fail -> .failure(retryExhausted).
/// session_id is stable across retries (the body is not regenerated).
final class UploadRetryTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeRequest() -> UploadRequest {
        UploadRequest(
            url: URL(string: "http://localhost:3000/api/v1/capture-sessions/job-1")!,
            token: "123456789ABCDEFGHJKLMNPQRSTUVWXY",
            bodyData: Data("multipart-body".utf8),
            boundary: "----b",
            sessionID: "5e551011-0000-4000-8000-000000000001"
        )
    }

    func testRetryThenSuccess() async {
        StubURLProtocol.responses = [
            .failure(URLError(.notConnectedToInternet)),
            .success(statusCode: 200, body: Data())
        ]
        let uploader = MultipartUploader(session: makeSession(), retryDelay: 0)
        let result = await uploader.upload(makeRequest())
        switch result {
        case .success:
            XCTAssertEqual(StubURLProtocol.attemptCount, 2)
        case .failure(let e):
            XCTFail("expected success after retry, got \(e)")
        }
    }

    func testBothFailRetryExhausted() async {
        StubURLProtocol.responses = [
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.notConnectedToInternet))
        ]
        let uploader = MultipartUploader(session: makeSession(), retryDelay: 0)
        let result = await uploader.upload(makeRequest())
        switch result {
        case .success:
            XCTFail("expected failure when both attempts fail")
        case .failure(let error):
            XCTAssertEqual(error, .retryExhausted)
            XCTAssertEqual(StubURLProtocol.attemptCount, 2)
        }
    }

    func testNon2xxIsFailure() async {
        StubURLProtocol.responses = [
            .success(statusCode: 401, body: Data()),
            .success(statusCode: 401, body: Data())
        ]
        let uploader = MultipartUploader(session: makeSession(), retryDelay: 0)
        let result = await uploader.upload(makeRequest())
        if case .failure(let error) = result {
            XCTAssertEqual(error, .unauthorized)
        } else {
            XCTFail("expected failure on 401")
        }
    }

    func testSessionIDStableAcrossRetries() async {
        StubURLProtocol.reset()
        StubURLProtocol.responses = [
            .failure(URLError(.timedOut)),
            .success(statusCode: 200, body: Data())
        ]
        StubURLProtocol.captureBodies = true
        let request = makeRequest()
        let uploader = MultipartUploader(session: makeSession(), retryDelay: 0)
        _ = await uploader.upload(request)
        // Both attempts carried the same body bytes (same session_id).
        XCTAssertEqual(StubURLProtocol.sentBodies.count, 2)
        XCTAssertEqual(StubURLProtocol.sentBodies[0], StubURLProtocol.sentBodies[1])
        // And the Authorization header is exactly the bearer value.
        XCTAssertEqual(StubURLProtocol.lastAuthorization, "Bearer 123456789ABCDEFGHJKLMNPQRSTUVWXY")
    }

    // MARK: - Server 5xx path

    /// Two consecutive 500 responses exhaust the retry budget and surface as
    /// `.retryExhausted` (5xx is not a special case like 401 — it retries once).
    func testServer500BothAttemptsExhaustsRetry() async {
        StubURLProtocol.responses = [
            .success(statusCode: 500, body: Data()),
            .success(statusCode: 500, body: Data())
        ]
        let uploader = MultipartUploader(session: makeSession(), retryDelay: 0)
        let result = await uploader.upload(makeRequest())
        switch result {
        case .success:
            XCTFail("expected failure on back-to-back 500s")
        case .failure(let error):
            XCTAssertEqual(error, .retryExhausted)
            XCTAssertEqual(StubURLProtocol.attemptCount, 2)
        }
    }

    // MARK: - File-streaming path

    /// The production upload path uses `bodyFileURL:` (streams from disk so the
    /// full bundle never sits in RAM). This test exercises that code path
    /// end-to-end: write body bytes to a temp file, build an UploadRequest via
    /// the `bodyFileURL:` init, and assert retry-then-success behaves identically
    /// to the in-memory path — and that the streamed body bytes are correct.
    func testFileStreamingPathRetryThenSuccess() async throws {
        let bodyBytes = Data("multipart-body-from-file".utf8)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-retry-test-\(UUID().uuidString).multipart")
        try bodyBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let request = UploadRequest(
            url: URL(string: "http://localhost:3000/api/v1/capture-sessions/job-1")!,
            token: "123456789ABCDEFGHJKLMNPQRSTUVWXY",
            bodyFileURL: tempURL,
            boundary: "----b",
            sessionID: "5e551011-0000-4000-8000-000000000001"
        )

        StubURLProtocol.responses = [
            .failure(URLError(.notConnectedToInternet)),
            .success(statusCode: 200, body: Data())
        ]
        StubURLProtocol.captureBodies = true

        let uploader = MultipartUploader(session: makeSession(), retryDelay: 0)
        let result = await uploader.upload(request)

        switch result {
        case .success:
            XCTAssertEqual(StubURLProtocol.attemptCount, 2,
                           "should have attempted twice (one failure + one success)")
            // Both attempts must have carried the exact same bytes from the file.
            XCTAssertEqual(StubURLProtocol.sentBodies.count, 2)
            XCTAssertEqual(StubURLProtocol.sentBodies[0], bodyBytes,
                           "streamed bytes must match the file contents")
            XCTAssertEqual(StubURLProtocol.sentBodies[0], StubURLProtocol.sentBodies[1],
                           "body must be identical across retries (stable session_id)")
        case .failure(let e):
            XCTFail("expected success after one retry on file-streaming path, got \(e)")
        }
    }
}

/// Stubs URLSession responses for retry tests.
// NOTE: static stub state assumes serial test execution. If Xcode ever runs
// these in parallel, the per-test reset() in tearDown() is insufficient and
// this should be refactored to an actor or per-test instance.
final class StubURLProtocol: URLProtocol {
    enum StubResponse {
        case failure(URLError)
        case success(statusCode: Int, body: Data)
    }

    static var responses: [StubResponse] = []
    static var attemptCount = 0
    static var captureBodies = false
    static var sentBodies: [Data] = []
    static var lastAuthorization: String?

    static func reset() {
        responses = []
        attemptCount = 0
        captureBodies = false
        sentBodies = []
        lastAuthorization = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index = Self.attemptCount
        Self.attemptCount += 1
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        if Self.captureBodies {
            if let stream = request.httpBodyStream {
                Self.sentBodies.append(Self.readStream(stream))
            } else if let body = request.httpBody {
                Self.sentBodies.append(body)
            } else {
                Self.sentBodies.append(Data())
            }
        }
        let response = index < Self.responses.count ? Self.responses[index] : .failure(URLError(.unknown))
        switch response {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let statusCode, let body):
            let http = HTTPURLResponse(url: request.url!, statusCode: statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
