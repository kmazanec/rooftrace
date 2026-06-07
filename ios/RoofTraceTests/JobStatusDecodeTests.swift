import XCTest
@testable import RoofTrace

final class JobStatusDecodeTests: XCTestCase {
    private func decode(status: String, shareToken: String? = "share-1", lastError: String? = "boom") throws -> JobStatusResponse {
        let shareValue = shareToken.map { "\"\($0)\"" } ?? "null"
        let errorValue = lastError.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id": "job-1",
          "address": "1 Main St",
          "status": "\(status)",
          "last_error": \(errorValue),
          "ready": false,
          "share_token": \(shareValue),
          "created_at": "2026-05-31T12:34:56.789Z"
        }
        """
        return try JSONDecoder.roofTraceAPI.decode(JobStatusResponse.self, from: Data(json.utf8))
    }

    func testDecodesEveryKnownStatus() throws {
        XCTAssertEqual(try decode(status: "pending").status, .pending)
        for stage in Stage.allCases {
            XCTAssertEqual(try decode(status: stage.rawValue).status, .processing(stage))
        }
        XCTAssertEqual(
            try decode(status: "ready", shareToken: "token-1").status,
            .ready(ReportLocator(jobID: "job-1", shareToken: "token-1"))
        )
        XCTAssertEqual(try decode(status: "failed", lastError: "nope").status, .failed(reason: "nope"))
    }

    func testUnknownStatusFallsBackWithoutThrowing() throws {
        XCTAssertEqual(try decode(status: "paused").status, .unknown("paused"))
    }

    func testReadyAndFailedTolerateMissingOptionalFields() throws {
        XCTAssertEqual(
            try decode(status: "ready", shareToken: nil).status,
            .ready(ReportLocator(jobID: "job-1", shareToken: nil))
        )
        XCTAssertEqual(
            try decode(status: "failed", lastError: nil).status,
            .failed(reason: "Measurement failed")
        )
    }

    func testCaptureCredentialIsOptional() throws {
        // Absent (token already expired server-side) → nil, no throw.
        let withoutToken = try decode(status: "ready")
        XCTAssertNil(withoutToken.captureToken)
        XCTAssertNil(withoutToken.captureTokenExpiresAt)
    }

    func testDecodesCaptureCredentialWhenPresent() throws {
        let json = """
        {
          "id": "job-1",
          "address": "1 Main St",
          "status": "fetching_imagery",
          "last_error": null,
          "ready": false,
          "share_token": null,
          "created_at": "2026-05-31T12:34:56.789Z",
          "capture_token": "scan-token-1",
          "capture_token_expires_at": "2026-06-01T12:34:56Z"
        }
        """
        let response = try JSONDecoder.roofTraceAPI.decode(JobStatusResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.captureToken, "scan-token-1")
        XCTAssertNotNil(response.captureTokenExpiresAt)
    }

    func testSharedDecoderAcceptsFractionalAndWholeSecondISO8601Dates() throws {
        let fractional = try decodeDate("2026-05-31T12:34:56.789Z")
        let whole = try decodeDate("2026-05-31T12:34:56Z")
        XCTAssertNotNil(fractional)
        XCTAssertNotNil(whole)
    }

    private func decodeDate(_ date: String) throws -> Date {
        let json = """
        {
          "app_token": "token",
          "expires_at": "\(date)"
        }
        """
        return try JSONDecoder.roofTraceAPI.decode(SessionResponse.self, from: Data(json.utf8)).expiresAt
    }
}
