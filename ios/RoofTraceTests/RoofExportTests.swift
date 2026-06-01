import CoreLocation
import XCTest
@testable import RoofTrace

final class RoofExportTests: XCTestCase {
    func testDecodesCommittedJSONExportFixture() throws {
        let export = try decodeFixture()

        XCTAssertEqual(export.schemaVersion, RoofExport.supportedSchemaVersion)
        XCTAssertEqual(export.job.id, "0f8d6b1e-3a4c-4c2e-9b1a-2d3e4f5a6b7c")
        XCTAssertEqual(export.measurement?.facets.first?.facetID, "F1")
        XCTAssertEqual(export.measurement?.features.first?.label, "chimney")
        XCTAssertEqual(export.artifacts.shareURL?.absoluteString, "https://rooftrace.biograph.dev/r/abc123example")
    }

    func testCoordinateConvertersKeepFacetAndGeoJSONOrderingSeparate() throws {
        let export = try decodeFixture()
        let vertex = try XCTUnwrap(export.measurement?.facets.first?.vertices.first)
        let facetCoord = try XCTUnwrap(coordFromFacetVertex(vertex))
        let geoJSONCoord = try XCTUnwrap(coordFromGeoJSON([vertex[1], vertex[0]]))

        assertCoordinate(facetCoord, latitude: 38.8977, longitude: -77.0365)
        assertCoordinate(geoJSONCoord, latitude: 38.8977, longitude: -77.0365)
    }

    func testNullMeasurementPayloadDecodesAndMapsToNotReady() throws {
        var payload = try fixtureObject()
        payload["measurement"] = NSNull()

        let data = try JSONSerialization.data(withJSONObject: payload)
        let export = try JSONDecoder.roofTraceAPI.decode(RoofExport.self, from: data)

        XCTAssertNil(export.measurement)
        XCTAssertEqual(ReportViewModel.state(for: export), .notReady)
    }

    func testMalformedFacetVerticesDecodeAndDropFromCoordinates() throws {
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
        let export = try JSONDecoder.roofTraceAPI.decode(RoofExport.self, from: data)
        let coordinates = try XCTUnwrap(export.measurement?.facets.first?.coordinates)

        XCTAssertEqual(coordinates.count, 1)
        assertCoordinate(coordinates[0], latitude: 38.8977, longitude: -77.0365)
    }

    func testUnexpectedSchemaVersionFailsDecode() throws {
        var payload = try fixtureObject()
        payload["schema_version"] = "2.0.0"
        let data = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try JSONDecoder.roofTraceAPI.decode(RoofExport.self, from: data))
    }

    private func decodeFixture() throws -> RoofExport {
        try JSONDecoder.roofTraceAPI.decode(RoofExport.self, from: fixtureData())
    }

    private func fixtureObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
    }

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func assertCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        latitude: CLLocationDegrees,
        longitude: CLLocationDegrees,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(coordinate.latitude, latitude, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(coordinate.longitude, longitude, accuracy: 0.000001, file: file, line: line)
    }
}
