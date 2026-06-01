import Foundation

/// Stubs URLSession responses for unit tests.
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
    static var lastRequest: URLRequest?

    static func reset() {
        responses = []
        attemptCount = 0
        captureBodies = false
        sentBodies = []
        lastAuthorization = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index = Self.attemptCount
        Self.attemptCount += 1
        Self.lastRequest = request
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
