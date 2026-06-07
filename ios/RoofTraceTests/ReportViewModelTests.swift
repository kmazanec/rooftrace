import MapKit
import XCTest
@testable import RoofTrace

@MainActor
final class ReportViewModelTests: XCTestCase {
    func testLoadReadyReportSetsReadyStateAndSelectedFacet() async throws {
        let export = try fixtureExport()
        let api = FakeAPIClient(results: [.success(export), .success(jobStatus())])
        let model = ReportViewModel(jobID: "job-1", api: api)

        await model.load()

        guard case .ready(let loaded) = model.state else {
            return XCTFail("expected ready state")
        }
        XCTAssertEqual(loaded.job.id, export.job.id)
        XCTAssertEqual(model.selectedFacetID, "F1")
        // load() fetches the export, then the status (for the scan credential).
        XCTAssertEqual(api.sentPaths, ["/api/v1/jobs/job-1.json", "/api/v1/jobs/job-1"])
    }

    func testLoadRecoversCaptureHandoffFromStatusWhenTokenUnexpired() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let api = FakeAPIClient(results: [
            .success(try fixtureExport()),
            .success(jobStatus(captureToken: "scan-tok", expiresAt: now.addingTimeInterval(3600)))
        ])
        let model = ReportViewModel(jobID: "job-1", api: api, now: { now })

        await model.load()

        XCTAssertEqual(model.captureHandoff, CaptureHandoff(token: "scan-tok", jobID: "job-1"))
    }

    func testLoadLeavesHandoffNilWhenTokenExpiredOrMissing() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let expired = FakeAPIClient(results: [
            .success(try fixtureExport()),
            .success(jobStatus(captureToken: "scan-tok", expiresAt: now.addingTimeInterval(-1)))
        ])
        let model = ReportViewModel(jobID: "job-1", api: expired, now: { now })
        await model.load()
        XCTAssertNil(model.captureHandoff)
    }

    func testLidarAvailabilityFollowsArtifactURL() async throws {
        let api = FakeAPIClient(results: [.success(try fixtureExport()), .success(jobStatus())])
        let model = ReportViewModel(jobID: "job-1", api: api)
        await model.load()
        // The committed fixture advertises a lidar_points_url.
        XCTAssertTrue(model.lidarAvailable)
    }

    private func jobStatus(captureToken: String? = nil, expiresAt: Date? = nil) -> JobStatusResponse {
        JobStatusResponse(
            id: "job-1",
            address: "1 Main St",
            status: .ready(ReportLocator(jobID: "job-1", shareToken: nil)),
            lastError: nil,
            ready: true,
            shareToken: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            captureToken: captureToken,
            captureTokenExpiresAt: expiresAt
        )
    }

    func testLoadNullMeasurementSetsNotReadyState() async throws {
        let api = FakeAPIClient(result: .success(try fixtureExport(measurementIsNull: true)))
        let model = ReportViewModel(jobID: "job-1", api: api)

        await model.load()

        XCTAssertEqual(model.state, .notReady)
        XCTAssertNil(model.selectedFacetID)
    }

    func testLoadErrorSetsRecoverableErrorState() async {
        let api = FakeAPIClient(result: .failure(APIError.unauthorized))
        let model = ReportViewModel(jobID: "job-1", api: api)

        await model.load()

        guard case .error(let message) = model.state else {
            return XCTFail("expected error state")
        }
        XCTAssertTrue(message.contains("Sign in"))
    }

    func testMapRectContainsFixtureCoordinates() throws {
        let export = try fixtureExport()
        let rect = try XCTUnwrap(ReportViewModel.mapRect(for: export))
        let coordinate = CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365)

        XCTAssertTrue(rect.contains(MKMapPoint(coordinate)))
        XCTAssertGreaterThan(rect.size.width, 0)
        XCTAssertGreaterThan(rect.size.height, 0)
    }

    func testMapRectIgnoresMalformedVertices() throws {
        let export = try fixtureExportWithMalformedVertices()
        let rect = try XCTUnwrap(ReportViewModel.mapRect(for: export))
        let valid = CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365)
        let invalid = CLLocationCoordinate2D(latitude: 38.8978, longitude: -77.0364)

        XCTAssertTrue(rect.contains(MKMapPoint(valid)))
        XCTAssertFalse(rect.contains(MKMapPoint(invalid)))
    }

    private func fixtureExport(measurementIsNull: Bool = false) throws -> RoofExport {
        var payload = try fixtureObject()
        if measurementIsNull {
            payload["measurement"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder.roofTraceAPI.decode(RoofExport.self, from: data)
    }

    private func fixtureExportWithMalformedVertices() throws -> RoofExport {
        var payload = try fixtureObject()
        var measurement = try XCTUnwrap(payload["measurement"] as? [String: Any])
        var facets = try XCTUnwrap(measurement["facets"] as? [[String: Any]])
        facets[0]["vertices"] = [
            [38.8977, -77.0365],
            [38.8978],
            NSNull(),
            ["bad", -77.0364],
            [91.0, -77.0364]
        ]
        measurement["facets"] = facets
        payload["measurement"] = measurement
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder.roofTraceAPI.decode(RoofExport.self, from: data)
    }

    private func fixtureObject() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
